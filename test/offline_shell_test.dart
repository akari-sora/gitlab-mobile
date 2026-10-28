// C3c-2 (§5.5, §5.9, §5.11, §6.7, §6.8, §8.3): the offline read-only shell.
// The app lock covers OfflineApp; unloaded, unreadable and refused lock states
// show no content; every banner state; every §6.7 confirmation outside the
// signed-in shell, before its action; zero outbound calls from the shell; the
// generation-keyed rebuild on entry and exit; 320 dp, 2x text, de and ar.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/offline/git_object_id.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/ai/ai_account_removal.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/features/offline/offline_app.dart';
import 'package:gitlab_mobile/features/offline/offline_gate.dart';
import 'package:gitlab_mobile/features/offline/offline_status.dart';
import 'package:gitlab_mobile/features/security/app_lock.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/incoming_links.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/main.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// The production dependency re-exports its value types, while this test needs
// the platform seams themselves to count browser and share calls.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';

const _snapshotId = '0123456789abcdef0123456789abcdef';
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _readme = '''
# Synthetic

[site](https://outside.example.org/page)

![ext](https://cdn.example.org/x.png)
''';

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  bool failOfflineKeyRead = false;
  @override
  Future<String?> read(String key) async {
    if (failOfflineKeyRead &&
        key.startsWith(ReadCacheKeyStore.offlineKeyPrefix)) {
      throw StateError('synthetic unavailable');
    }
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

final class _LockStore implements AppLockStore {
  bool enabled = false, fail = false;
  Completer<void>? pending;
  @override
  Future<bool> read() async {
    await pending?.future;
    if (fail) throw StateError('synthetic lock read failure');
    return enabled;
  }

  @override
  Future<void> write(bool enabled) async => this.enabled = enabled;
}

final class _Auth implements AppLockAuthenticator {
  bool pass = false;
  int calls = 0;
  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    return pass;
  }

  @override
  Future<bool> available() async => true;
}

final class _FakeLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  int calls = 0;
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls++;
    return true;
  }
}

final class _FakeShare extends SharePlatform with MockPlatformInterfaceMixin {
  int calls = 0;
  @override
  Future<ShareResult> share(ShareParams params) async {
    calls++;
    return ShareResult.unavailable;
  }
}

/// Counts every dart:io HTTP client, the transport any unmocked request
/// (Dio's default adapter, network images) would need.
final class _CountingHttp extends HttpOverrides {
  _CountingHttp(this.previous);
  final HttpOverrides? previous;
  int clients = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    return previous?.createHttpClient(context) ??
        super.createHttpClient(context);
  }
}

DioException _offlineError() => DioException(
  requestOptions: RequestOptions(),
  type: DioExceptionType.connectionError,
);

ResponseBody _network(RequestOptions request) => throw DioException(
  requestOptions: request,
  type: DioExceptionType.connectionError,
);

final class _Harness {
  _Harness(this.responder) {
    keys = ReadCacheKeyStore(storage);
    cache = ReadCacheDiskCoordinator(
      keys: keys,
      files: ReadCacheFileStore(root: () async => root),
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: true,
      clock: () => now,
    );
    lock = AppLockController(store: lockStore, authenticator: auth);
    store.accounts = [account, other];
    store.lastActive = account.key;
  }

  final root = Directory.systemTemp.createTempSync('offline-shell-');
  final storage = _Storage();
  final lockStore = _LockStore();
  final auth = _Auth();
  final store = MemoryAccountStore();
  final account = Account(
    instance: GitLabInstance.parse('https://example.test'),
    user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
    token: 'synthetic',
  );
  final other = Account(
    instance: GitLabInstance.parse('https://example.test'),
    user: const GitLabUser(id: 8, username: 'other', name: 'Other'),
    token: 'synthetic-other',
  );
  Responder responder;
  late final adapter = FakeAdapter((request) => responder(request));
  late final ReadCacheKeyStore keys;
  late final ReadCacheDiskCoordinator cache;
  late final AppLockController lock;
  final links = IncomingLinks(null);
  final appearance = AppearanceController(MemoryAppearanceStore());
  int contentClients = 0;
  final sessions = <SessionController>[];
  DateTime now = DateTime.utc(2026, 10, 28);

  Iterable<RequestOptions> get nonIdentityRequests =>
      adapter.requests.where((r) => !r.uri.path.endsWith('/api/v4/user'));

  Future<void> seed({DateTime? validatedAt}) async {
    await keys.writeOfflineKey(account.key, Uint8List(32));
    final store = SnapshotStore(
      supportRoot: root,
      accountKey: account.key,
      rootKey: Uint8List(32),
    );
    const format = SnapshotObjectFormat.sha1;
    final entries = <SnapshotTreeEntry>[];
    for (final (path, text) in [
      ('README.md', _readme),
      ('main.dart', 'void main() {}\n'),
    ]) {
      final bytes = utf8.encode(text);
      final id = gitBlobId(bytes, 'sha1');
      await store.writeBlob(format, id, bytes, mayCommit: () => true);
      entries.add(
        SnapshotTreeEntry(
          path: path,
          type: SnapshotEntryType.blob,
          mode: '100644',
          id: id,
          state: SnapshotEntryState.saved,
          kind: SnapshotContentKind.text,
          size: bytes.length,
        ),
      );
    }
    final record = SnapshotRecord(
      id: _snapshotId,
      projectId: 42,
      projectPath: 'group/project',
      projectName: 'Project',
      defaultBranch: 'main',
      refKind: SnapshotRefKind.branch,
      refName: 'main',
      sha: _sha,
      objectFormat: format,
      subPath: '',
      commitTitle: 'title',
      committedAt: now,
      status: SnapshotStatus.complete,
      createdAt: now,
      savedAt: now,
      entryCount: entries.length,
      savedCount: entries.length,
      storedBytes: 4096,
    );
    await store.writeTree(
      SnapshotTree(
        snapshotId: record.id,
        sha: record.sha,
        subPath: '',
        entries: entries,
      ),
      format: format,
      complete: true,
      mayCommit: () => true,
    );
    await store.writeIndex(
      SnapshotIndex(
        accountKey: account.key,
        lastValidatedAt: validatedAt ?? now,
        consentAt: now,
        snapshots: [record],
      ),
      expectedRevision: store.revision,
      mayCommit: () => true,
    );
  }

  /// [recover] runs startup recovery the way `main` does, for sessions that
  /// are not started by the app root.
  SessionController makeSession({
    bool recover = true,
    ApplicationIdLookup? applicationIdFor,
  }) {
    GitLabApi client(
      GitLabInstance instance,
      AccountCredential credential,
      OAuthTokenClient? oauth,
      Future<void> Function(OAuthCredential) onRotated, [
      GitLabRateBudget? budget,
    ]) => GitLabApi(
      instance: instance,
      credential: credential,
      dio: Dio()..httpClientAdapter = adapter,
      oauth: oauth,
      onOAuthRotated: onRotated,
      rateBudget: budget,
    );
    final session = SessionController(
      store,
      readCache: cache,
      appLock: lock,
      clock: () => now,
      applicationIdFor: applicationIdFor,
      createApi: (instance, credential, oauth, onRotated) {
        contentClients++;
        return client(instance, credential, oauth, onRotated);
      },
      createIdentityApi: client,
    );
    if (recover) {
      final decisions = <Object>{};
      session.addListener(() {
        final decision = session.readCacheStartupDecision;
        if (decision != null && decisions.add(decision)) {
          unawaited(
            cache.recover(
              decision,
              accountKeys: session.accounts.map((a) => a.key).toSet(),
              sessionOwner: session,
            ),
          );
        }
      });
    }
    sessions.add(session);
    return session;
  }

  /// A session that entered offline mode by itself (network failure).
  Future<SessionController> offlineSession(WidgetTester tester) async {
    late SessionController session;
    await tester.runAsync(() async {
      await seed();
      await lock.start();
      session = makeSession();
      await session.initialize();
      // Deterministic tests: no background retry timer.
      session.offlineGate.connectionSucceeded();
    });
    expect(
      session.offline,
      isNotNull,
      reason:
          'offline entry: message=${session.message} '
          'lock=${session.offlineGate.lockReadable} '
          'recovered=${cache.startupRecovered} '
          'retained=${cache.diskRetainedAccountKey}',
    );
    return session;
  }

  Widget app(SessionController session) => OfflineApp(
    key: ValueKey(session.generation),
    session: session,
    appearance: appearance,
    lock: lock,
    incoming: links,
  );

  /// Ends every timer owned by the sessions before the test ends.
  void stop() {
    for (final session in sessions) {
      if (!session.isDisposed) session.dispose();
    }
  }

  /// Widget tests drain storage in [_finish]: a tear-down runs on the fake
  /// clock, where native I/O never completes.
  Future<void> dispose({bool quiesce = true}) async {
    stop();
    lock.dispose();
    links.dispose();
    appearance.dispose();
    if (quiesce) await cache.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Finder get _projectRow =>
    find.byKey(const ValueKey('offline-shell-row-$_snapshotId'));

Future<void> _until(
  WidgetTester tester,
  bool Function() condition, {
  String? what,
  int cycles = 300,
}) => pumpUntil(tester, condition, maxCycles: cycles, description: what);

/// Storage objects live on the real event loop: a future they keep must not
/// belong to the widget clock, where native I/O never finishes.
Future<_Harness> _realHarness(WidgetTester tester, Responder responder) async =>
    (await tester.runAsync(() async => _Harness(responder)))!;

/// Lets dialogs and routes animate without waiting for spinners to stop.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Stops the sessions' timers and lets dialog controllers be disposed.
Future<void> _finish(WidgetTester tester, _Harness h) async {
  h.stop();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await pumpUntilComplete(tester, h.cache.quiesced);
}

Future<void> _shown(WidgetTester tester, Finder finder) =>
    _until(tester, () => finder.evaluate().isNotEmpty, what: finder.toString());

void main() {
  late _FakeLauncher launcher;
  late _FakeShare sharer;
  late UrlLauncherPlatform originalLauncher;
  late SharePlatform originalShare;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // The shell runs with the production flag: it is on since C3c-2.
    offlineModeShellReadyForTesting = null;
    launcher = _FakeLauncher();
    sharer = _FakeShare();
    originalLauncher = UrlLauncherPlatform.instance;
    originalShare = SharePlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    SharePlatform.instance = sharer;
    addTearDown(() {
      offlineModeShellReadyForTesting = null;
      UrlLauncherPlatform.instance = originalLauncher;
      SharePlatform.instance = originalShare;
    });
  });

  group('banner text', () {
    final now = DateTime.utc(2026, 10, 28, 12);
    test('every no-verdict reason has its own first line (§6.8)', () {
      expect(offlineBannerText(null, now), '尚未連上 GitLab · 只能瀏覽已保存的專案');
      expect(
        offlineBannerText(const ApiFailure(FailureKind.network), now),
        '離線 · 只能瀏覽已保存的專案',
      );
      expect(
        offlineBannerText(const ApiFailure(FailureKind.server), now),
        'GitLab 暫時沒有回應 · 只能瀏覽已保存的專案',
      );
      expect(
        offlineBannerText(const ApiFailure(FailureKind.rateLimited), now),
        'GitLab 限流中 · 只能瀏覽已保存的專案',
      );
      expect(
        offlineBannerText(
          ApiFailure(
            FailureKind.rateLimited,
            retryAt: now.add(const Duration(minutes: 4, seconds: 10)),
          ),
          now,
        ),
        'GitLab 限流中（約 5 分鐘）· 只能瀏覽已保存的專案',
      );
      expect(
        offlineBannerText(
          ApiFailure(
            FailureKind.rateLimited,
            retryAt: now.subtract(const Duration(minutes: 1)),
          ),
          now,
        ),
        'GitLab 限流中 · 只能瀏覽已保存的專案',
      );
      for (final kind in [
        FailureKind.redirectBlocked,
        FailureKind.invalidResponse,
      ]) {
        expect(
          offlineBannerText(ApiFailure(kind), now),
          '網路可能需要登入（例如 Wi-Fi 認證頁）· 只能瀏覽已保存的專案',
        );
      }
    });
  });

  group('app root', () {
    testWidgets(
      'auto entry renders OfflineApp keyed by generation; leaving confirms '
      'and rebuilds to sign-in with shortcuts cleared',
      (tester) async {
        final h = _Harness(_network);
        addTearDown(() => h.dispose(quiesce: false));
        await tester.runAsync(() async {
          await h.seed();
        });
        final session = h.makeSession(recover: false);
        final host = FakeAppShortcutHost();
        final shortcuts = LauncherShortcuts(host, MemoryRecentProjectStore());
        addTearDown(shortcuts.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sessionProvider.overrideWithValue(session),
              appLockProvider.overrideWithValue(h.lock),
              incomingLinksProvider.overrideWithValue(h.links),
              launcherShortcutsProvider.overrideWithValue(shortcuts),
              appearanceProvider.overrideWithValue(h.appearance),
            ],
            child: const GitLabMobileApp(),
          ),
        );
        await _until(tester, () => session.offline != null, what: 'entry');
        await _shown(tester, _projectRow);
        final shell = tester.widget<OfflineApp>(find.byType(OfflineApp));
        expect(shell.key, ValueKey(session.generation));
        expect(session.offline!.generation, session.generation);
        expect(find.byType(AuthenticatedApp), findsNothing);
        expect(find.byType(LoginScreen), findsNothing);
        expect(find.text('離線 · 只能瀏覽已保存的專案'), findsOneWidget);
        expect(find.text('@coder'), findsOneWidget);
        expect(h.contentClients, 0, reason: 'no account API client offline');
        expect(host.clears, 0);

        // Leaving confirms the loss first; cancelling changes nothing.
        await tester.tap(find.byKey(const ValueKey('offline-shell-menu')));
        await _settle(tester);
        await tester.tap(find.text('改用其他帳號'));
        await _shown(tester, find.text('要刪除離線專案嗎？'));
        expect(find.text('切換帳號會刪除 @coder 的 1 個離線專案（4.0 KB）。'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await _settle(tester);
        expect(session.offline, isNotNull);

        final generation = session.generation;
        await tester.tap(find.byKey(const ValueKey('offline-shell-menu')));
        await _settle(tester);
        await tester.tap(find.text('改用其他帳號'));
        await _shown(tester, find.text('繼續並刪除'));
        await tester.tap(find.text('繼續並刪除'));
        await _until(
          tester,
          () => find.byType(LoginScreen).evaluate().isNotEmpty,
        );
        expect(session.offline, isNull);
        expect(session.generation, greaterThan(generation));
        expect(find.byType(OfflineApp), findsNothing);
        expect(find.byType(LoginScreen), findsOneWidget);
        expect(host.clears, 1, reason: 'leaving offline clears shortcuts');
        await _finish(tester, h);
      },
    );

    testWidgets('the resume screen offers offline browsing and confirms '
        'leaving the account before anything stops', (tester) async {
      final pending = Completer<ResponseBody>();
      final h = _Harness((_) => pending.future);
      addTearDown(() => h.dispose(quiesce: false));
      await tester.runAsync(() async {
        await h.seed();
      });
      final session = h.makeSession(recover: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWithValue(session),
            appLockProvider.overrideWithValue(h.lock),
            incomingLinksProvider.overrideWithValue(h.links),
            appearanceProvider.overrideWithValue(h.appearance),
          ],
          child: const GitLabMobileApp(),
        ),
      );
      final browse = find.byKey(const ValueKey('resume-browse-offline'));
      await _shown(tester, browse);
      expect(session.resuming, isTrue);
      expect(find.text('離線瀏覽'), findsOneWidget);

      // "Use another account" asks first; cancelling keeps resuming.
      await tester.tap(
        find.byKey(const ValueKey('resume-use-another-account')),
      );
      await _shown(tester, find.text('要刪除離線專案嗎？'));
      expect(find.text('切換帳號會刪除 @coder 的 1 個離線專案（4.0 KB）。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(session.resuming, isTrue);

      // Early entry while /user still runs.
      final before = session.generation;
      await tester.tap(browse);
      await _until(tester, () => session.offline != null, what: 'early entry');
      await _shown(tester, _projectRow);
      expect(session.generation, greaterThan(before));
      expect(find.byType(OfflineApp), findsOneWidget);
      expect(
        find.byKey(const ValueKey('offline-banner-probing')),
        findsOneWidget,
        reason: 'the first check still runs',
      );
      expect(find.text('尚未連上 GitLab · 只能瀏覽已保存的專案'), findsOneWidget);
      pending.completeError(_offlineError());
      await _until(
        tester,
        () => find.text('離線 · 只能瀏覽已保存的專案').evaluate().isNotEmpty,
      );
      await _finish(tester, h);
    });
  });

  group('lock', () {
    testWidgets('a lock that is on covers OfflineApp; a refused unlock keeps '
        'it covered', (tester) async {
      final h = await _realHarness(tester, _network);
      addTearDown(() => h.dispose(quiesce: false));
      h.lockStore.enabled = true;
      final session = await h.offlineSession(tester);
      expect(h.lock.locked, isTrue);
      await tester.pumpWidget(h.app(session));
      await _until(tester, () => h.auth.calls > 0, what: 'unlock prompt');
      await _shown(tester, find.byKey(const ValueKey('app-lock-unlock')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(h.lock.locked, isTrue, reason: 're-auth failed');
      expect(_projectRow.hitTestable(), findsNothing);
      expect(find.text('Project').hitTestable(), findsNothing);

      h.auth.pass = true;
      await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await _shown(tester, _projectRow.hitTestable());
      expect(h.lock.locked, isFalse);
      await _finish(tester, h);
    });

    testWidgets('an unloaded or unreadable lock setting shows no content and '
        'offers a retry', (tester) async {
      final h = await _realHarness(tester, _network);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await h.offlineSession(tester);
      await tester.pumpWidget(h.app(session));
      await _shown(tester, _projectRow.hitTestable());

      // Reading again: covered until the read ends.
      final gate = h.lockStore.pending = Completer<void>();
      unawaited(h.lock.reload());
      await tester.pump();
      expect(h.lock.loaded, isFalse);
      expect(_projectRow.hitTestable(), findsNothing);

      // The read fails: the unreadable cover, still nothing behind it.
      h.lockStore.fail = true;
      gate.complete();
      await _shown(
        tester,
        find.byKey(const ValueKey('offline-lock-unreadable')),
      );
      expect(h.lock.loadFailed, isTrue);
      expect(find.text('無法讀取 App 鎖定設定'), findsOneWidget);
      expect(_projectRow.hitTestable(), findsNothing);
      expect(find.semantics.byLabel(RegExp('Project')), findsNothing);

      // Retry reads again through reload().
      h.lockStore
        ..pending = null
        ..fail = false;
      await tester.tap(find.byKey(const ValueKey('offline-lock-retry')));
      await _shown(tester, _projectRow.hitTestable());
      expect(
        find.byKey(const ValueKey('offline-lock-unreadable')),
        findsNothing,
      );
      await _finish(tester, h);
    });
  });

  group('banner states', () {
    testWidgets('offline, checking and restored; a manual retry that fails '
        'says so', (tester) async {
      final h = await _realHarness(
        tester,
        (_) => jsonResponse({'message': 'unavailable'}, status: 503),
      );
      addTearDown(() => h.dispose(quiesce: false));
      final session = await h.offlineSession(tester);
      await tester.pumpWidget(h.app(session));
      await _shown(tester, _projectRow);
      expect(
        find.byKey(const ValueKey('offline-banner-offline')),
        findsOneWidget,
      );
      expect(find.text('GitLab 暫時沒有回應 · 只能瀏覽已保存的專案'), findsOneWidget);
      expect(find.text('重試連線'), findsOneWidget);

      // Checking: spinner, button disabled.
      final hold = Completer<ResponseBody>();
      h.responder = (_) => hold.future;
      await tester.tap(find.byKey(const ValueKey('offline-banner-action')));
      await _shown(
        tester,
        find.byKey(const ValueKey('offline-banner-probing')),
      );
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('offline-banner-action')),
      );
      expect(button.onPressed, isNull);
      hold.completeError(_offlineError());
      await _shown(tester, find.text('仍然無法連上 GitLab'));
      expect(
        find.byKey(const ValueKey('offline-banner-offline')),
        findsOneWidget,
      );
      expect(find.text('離線 · 只能瀏覽已保存的專案'), findsOneWidget);
      expect(session.offline, isNotNull);

      // A background check that confirms the account only changes the banner.
      h.responder = (_) =>
          jsonResponse({'id': 7, 'username': 'coder', 'name': 'Coder'});
      await tester.runAsync(() => session.probeOffline(manual: false));
      await _shown(
        tester,
        find.byKey(const ValueKey('offline-banner-restored')),
      );
      expect(session.offline, isNotNull);
      expect(find.text('切換到線上'), findsWidgets);
      expect(
        find.byKey(const ValueKey('offline-restored-snack')),
        findsOneWidget,
      );
      expect(h.contentClients, 0);
      await _finish(tester, h);
    });

    testWidgets('switch to online from a saved project goes online with its '
        'repository as the resume target', (tester) async {
      final h = await _realHarness(tester, _network);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await h.offlineSession(tester);
      await tester.pumpWidget(h.app(session));
      await _shown(tester, _projectRow);
      await tester.tap(_projectRow);
      await _shown(tester, find.byKey(const ValueKey('snapshot-readme')));

      h.responder = (_) =>
          jsonResponse({'id': 7, 'username': 'coder', 'name': 'Coder'});
      await tester.runAsync(() => session.probeOffline(manual: false));
      final snack = find.byKey(const ValueKey('offline-restored-snack'));
      await _shown(tester, snack);
      await _settle(tester);
      // The page below the open one keeps a copy of the snack bar.
      await tester.tap(
        find
            .descendant(of: snack, matching: find.byType(SnackBarAction))
            .hitTestable()
            .first,
      );
      await _until(tester, () => session.active != null, what: 'online');
      expect(session.offline, isNull);
      expect(session.api, isNotNull);
      final target = session.pendingResumeTarget;
      expect(target?.projectId, 42);
      expect(target?.resource, 'repository');
      await _finish(tester, h);
    });

    testWidgets('a link from another app is shown as pending, not taken', (
      tester,
    ) async {
      final h = await _realHarness(tester, _network);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await h.offlineSession(tester);
      await tester.pumpWidget(h.app(session));
      await _shown(tester, _projectRow);
      expect(find.byKey(const ValueKey('offline-pending-link')), findsNothing);
      final link = Uri.parse('https://example.test/group/project/-/issues/1');
      h.links.offer(link);
      await _shown(tester, find.text('連線後會開啟 1 個連結'));
      expect(h.links.pending, link);
      await _finish(tester, h);
    });
  });

  testWidgets('the offline shell sends nothing: README, an outside link and a '
      'file through recording GitLabApi, transport, launcher and sharer', (
    tester,
  ) async {
    final previous = HttpOverrides.current;
    final http = _CountingHttp(previous);
    HttpOverrides.global = http;
    addTearDown(() => HttpOverrides.global = previous);
    final clipboard = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final h = await _realHarness(tester, _network);
    addTearDown(() => h.dispose(quiesce: false));
    final session = await h.offlineSession(tester);
    final identity = h.adapter.requests.length;
    await tester.pumpWidget(h.app(session));
    await _shown(tester, _projectRow);
    await tester.tap(_projectRow);
    await _shown(tester, find.byKey(const ValueKey('snapshot-readme')));
    await _until(
      tester,
      () => find.text('離線時不載入').evaluate().isNotEmpty,
      what: 'external image placeholder',
    );
    await tester.ensureVisible(find.text('site', findRichText: true));
    await _settle(tester);
    await tester.tap(find.text('site', findRichText: true));
    await _settle(tester);
    expect(find.byKey(const ValueKey('snapshot-link-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snapshot-link-copy')));
    await _settle(tester);
    expect(clipboard, hasLength(1));
    await tester.tap(find.text('main.dart'));
    await _until(
      tester,
      () => find
          .textContaining('void main()', findRichText: true)
          .evaluate()
          .isNotEmpty,
      what: 'file preview',
    );
    await settleNetworkWidgets(tester);

    expect(h.contentClients, 0, reason: 'no content-capable GitLabApi');
    expect(h.nonIdentityRequests, isEmpty);
    expect(h.adapter.requests.length, identity, reason: 'no new /user either');
    expect(http.clients, 0, reason: 'no outside transport');
    expect(launcher.calls, 0);
    expect(sharer.calls, 0);
    await _finish(tester, h);
  });

  group('layout', () {
    for (final tag in ['de', 'ar', 'zh-TW']) {
      testWidgets('320 dp at 2x text in $tag: no overflow, the banner button '
          'under its text', (tester) async {
        final h = await _realHarness(tester, _network);
        addTearDown(() => h.dispose(quiesce: false));
        final session = await h.offlineSession(tester);
        useLanguage(languageForTag(tag)!);
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        h.links.offer(Uri.parse('https://example.test/group/project'));
        await tester.pumpWidget(h.app(session));
        await _shown(
          tester,
          find.byKey(const ValueKey('offline-banner-offline')),
        );
        final repositories = OfflineScope.maybeOf(
          tester.element(find.byType(Scaffold).first),
          listen: false,
        )!;
        await _until(
          tester,
          () => repositories.snapshots.isNotEmpty && !repositories.loading,
          what: 'snapshots loaded',
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final banner = find.byKey(const ValueKey('offline-banner-offline'));
        final button = find.byKey(const ValueKey('offline-banner-action'));
        final text = find.descendant(
          of: banner,
          matching: find.text(
            offlineBannerText(session.offline!.reason, h.now),
          ),
        );
        expect(
          tester.getTopLeft(button).dy,
          greaterThan(tester.getBottomLeft(text).dy - 1),
        );
        // The square test glyphs make 2x German very tall: scroll to each part.
        await tester.scrollUntilVisible(
          find.text(l10n.offlinePendingLink),
          200,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('offline-shell-account')),
          200,
        );
        await tester.scrollUntilVisible(_projectRow, 200);
        expect(
          Directionality.of(tester.element(_projectRow)),
          tag == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('offline-shell-manage')),
          200,
        );
        expect(tester.takeException(), isNull);
        await _finish(tester, h);
      });
    }
  });

  group('sign-in screen (§6.7)', () {
    /// A failed resume that keeps @coder's data (validation error: unknown).
    Future<SessionController> retained(
      WidgetTester tester,
      _Harness h, {
      ApplicationIdLookup? applicationIdFor,
    }) async {
      late SessionController session;
      await tester.runAsync(() async {
        await h.seed();
        await h.lock.start();
        session = h.makeSession(applicationIdFor: applicationIdFor);
        await session.initialize();
        for (
          var i = 0;
          i < 100 && session.diskRetainedAccountKey == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(session.offline, isNull);
      expect(session.active, isNull);
      expect(session.diskRetainedAccountKey, h.account.key);
      return session;
    }

    Future<void> pumpLogin(WidgetTester tester, SessionController session) =>
        tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));

    Future<_Harness> unknownFailure(WidgetTester tester) => _realHarness(
      tester,
      (_) => jsonResponse({'message': 'bad'}, status: 400),
    );

    testWidgets('picking another account confirms the retained account loss '
        'first; the retained account itself asks nothing', (tester) async {
      final h = await unknownFailure(tester);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await retained(tester, h);
      await pumpLogin(tester, session);
      await _settle(tester);
      final before = h.adapter.requests.length;
      await tester.tap(find.text('@other'));
      await _shown(tester, find.text('要刪除離線專案嗎？'));
      expect(find.text('切換帳號會刪除 @coder 的 1 個離線專案（4.0 KB）。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(h.adapter.requests.length, before, reason: 'nothing ran');
      expect(session.diskRetainedAccountKey, h.account.key);

      // B8: the retained account itself retries without a dialog.
      await tester.tap(find.text('@coder'));
      await tester.pump();
      expect(find.text('要刪除離線專案嗎？'), findsNothing);
      await _until(tester, () => !session.busy, what: 'retry ends');
      expect(h.adapter.requests.length, greaterThan(before));
      await _finish(tester, h);
    });

    testWidgets('signing in with a token confirms the retained account loss '
        'before connecting', (tester) async {
      final h = await unknownFailure(tester);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await retained(tester, h);
      await pumpLogin(tester, session);
      await _settle(tester);
      final before = h.adapter.requests.length;
      await tester.enterText(find.byKey(const Key('tokenField')), 'glpat-x');
      await tester.ensureVisible(find.byKey(const Key('connectButton')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('connectButton')));
      await _shown(tester, find.text('要刪除離線專案嗎？'));
      expect(
        find.text('若登入的是其他帳號，會刪除 @coder 的 1 個離線專案（4.0 KB）。'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(h.adapter.requests.length, before);
      expect(session.busy, isFalse);
      await _finish(tester, h);
    });

    testWidgets('GitLab sign-in confirms the retained account loss before '
        'the browser opens', (tester) async {
      final h = await unknownFailure(tester);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await retained(
        tester,
        h,
        applicationIdFor: (_) => 'synthetic-application',
      );
      await pumpLogin(tester, session);
      await _settle(tester);
      final message = session.message;
      final oauth = find.byKey(const Key('oauthButton'));
      await tester.ensureVisible(oauth);
      await _settle(tester);
      await tester.tap(oauth);
      await _shown(tester, find.text('要刪除離線專案嗎？'));
      expect(
        find.text('若登入的是其他帳號，會刪除 @coder 的 1 個離線專案（4.0 KB）。'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(session.message, message, reason: 'sign-in never started');
      expect(session.busy, isFalse);
      await _finish(tester, h);
    });

    testWidgets('removing the retained account confirms the loss before the '
        'removal hold and its own dialogs', (tester) async {
      final h = await unknownFailure(tester);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await retained(tester, h);
      await pumpLogin(tester, session);
      await _settle(tester);
      await tester.tap(find.byKey(Key('removeAccount-${h.account.key}')));
      await _shown(tester, find.text('要刪除離線專案嗎？'));
      expect(find.text('移除帳號會刪除 @coder 的 1 個離線專案（4.0 KB）。'), findsOneWidget);
      expect(AiAccountRemoval.anyRunning, isFalse, reason: 'no hold yet');
      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(AiAccountRemoval.anyRunning, isFalse);
      expect(session.accounts, hasLength(2));

      // Another account has no offline data here: no offline dialog.
      await tester.tap(find.byKey(Key('removeAccount-${h.other.key}')));
      await tester.pump();
      expect(find.text('要刪除離線專案嗎？'), findsNothing);
      await _finish(tester, h);
    });

    testWidgets('a count that cannot be read still asks, without a number', (
      tester,
    ) async {
      final h = await unknownFailure(tester);
      addTearDown(() => h.dispose(quiesce: false));
      final session = await retained(tester, h);
      h.storage.failOfflineKeyRead = true;
      await pumpLogin(tester, session);
      await _settle(tester);
      await tester.tap(find.text('@other'));
      await _shown(tester, find.text('要刪除離線專案嗎？'));
      expect(find.text('會刪除 @coder 在這台裝置上的離線專案（目前無法讀取數量）。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _settle(tester);
      await _finish(tester, h);
    });
  });

  group('session messages', () {
    test('a GitLab 401 while offline says the data is being deleted, then '
        'that it was deleted', () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      await session.initialize();
      expect(session.offline, isNotNull);
      final messages = <String?>[];
      session.addListener(() {
        if (messages.lastOrNull != session.message) {
          messages.add(session.message);
        }
      });
      h.responder = (_) => jsonResponse({'message': 'denied'}, status: 401);
      await session.probeOffline(manual: false);
      expect(session.offline, isNull);
      expect(messages, contains('登入已失效，正在刪除 @coder 的離線資料。'));
      for (
        var i = 0;
        i < 200 && session.message != '登入已失效，已刪除 @coder 的離線資料。';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.message, '登入已失效，已刪除 @coder 的離線資料。');
      expect((await h.keys.readOfflineKey(h.account.key)).isFound, isFalse);
    });

    test(
      '30 days after the last verification the shell ends with a reason',
      () async {
        final h = _Harness(_network);
        addTearDown(h.dispose);
        await h.seed();
        await h.lock.start();
        final session = h.makeSession();
        await session.initialize();
        expect(session.offline, isNotNull);
        h.now = h.now.add(const Duration(days: 31));
        expect(session.offlineGate.recheckAge(), isFalse);
        expect(session.offline, isNull);
        expect(session.message, l10n.offlineValidationExpired);
        expect((await h.keys.readOfflineKey(h.account.key)).isFound, isTrue);
      },
    );

    test('a later no-verdict check withdraws "connection restored"', () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      await h.seed();
      await h.lock.start();
      final session = h.makeSession();
      await session.initialize();
      h.responder = (_) => jsonResponse({'id': 7, 'username': 'coder'});
      await session.probeOffline(manual: false);
      expect(session.offline?.connectionRestored, isTrue);
      h.responder = (_) => jsonResponse({'message': 'busy'}, status: 429);
      await session.probeOffline(manual: false);
      expect(session.offline?.connectionRestored, isFalse);
      expect(session.offline?.reason?.kind, FailureKind.rateLimited);
    });

    test('the retained summary only reads: absent, counted, unknown', () async {
      final h = _Harness(_network);
      addTearDown(h.dispose);
      expect(await h.cache.offlineSnapshotSummary(h.account.key), (
        count: 0,
        bytes: 0,
      ));
      await h.seed();
      final before = Map.of(h.storage.values);
      expect(await h.cache.offlineSnapshotSummary(h.account.key), (
        count: 1,
        bytes: 4096,
      ));
      h.storage.failOfflineKeyRead = true;
      expect(await h.cache.offlineSnapshotSummary(h.account.key), isNull);
      expect(h.storage.values, before, reason: 'nothing written');
    });
  });
}
