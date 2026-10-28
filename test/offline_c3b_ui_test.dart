// C3b widget tests (§8.3): zero outbound while browsing a snapshot, the
// snapshot media policy, the AI regression of MarkdownView(offline: true),
// every state of the sheet, chip and explainer, the offline projects page,
// the .gitattributes hint and the layouts (320 dp, 2x, de, ar, keyboard).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/offline/git_object_id.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/features/offline/offline_consent_dialog.dart';
import 'package:gitlab_mobile/features/offline/offline_projects_page.dart';
import 'package:gitlab_mobile/features/offline/offline_repositories.dart';
import 'package:gitlab_mobile/features/offline/offline_status.dart';
import 'package:gitlab_mobile/features/offline/save_sheet.dart';
import 'package:gitlab_mobile/features/offline/snapshot_browser_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/external_link.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/network_boundary.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// The production dependency re-exports its value types, while this test needs
// the platform seams themselves to count browser and share calls.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'offline/coordinator_regression_test.dart' as fixture;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _host = 'https://example.test';
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _id = '0123456789abcdef0123456789abcdef';
final _account = Account(
  instance: GitLabInstance.parse(_host),
  user: const GitLabUser(id: 1, username: 'coder', name: 'Coder'),
  token: 'synthetic-test-token',
);
final _binding = DiskBinding(accountKey: _account.key, generation: 1);
final _date = DateTime.utc(2026, 10, 28);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

const _readme = '''
# Synthetic

![ok](docs/a.png)
![gone](docs/missing.png)
![ext](https://cdn.example.org/x.png)
![other](https://example.test/other/project/-/raw/$_sha/docs/a.png)
![otherref](https://example.test/group/project/-/raw/feature/docs/a.png)

[site](https://outside.example.org/page)

[code](src/main.dart)
''';

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

/// A completed synthetic snapshot of group/project at [_sha] on disk.
final class _Snap {
  _Snap(this.root, this.keys, this.owner, this.store, this.record);
  final Directory root;
  final fixture.MemoryKeys keys;
  final OfflineRepositoryCoordinator owner;
  final SnapshotStore store;
  final SnapshotRecord record;

  static Future<_Snap> create({
    bool readOnly = true,
    String? headSha,
    SnapshotProbe? probe,
    List<SnapshotRecord> more = const [],
    bool open = true,
  }) async {
    final scratch = Directory('.dart_tool/c3b/ui')..createSync(recursive: true);
    final root = scratch.createTempSync('case.');
    final keys = fixture.MemoryKeys();
    final store = SnapshotStore(
      supportRoot: root,
      accountKey: _account.key,
      rootKey: Uint8List(32),
    );
    final owner = OfflineRepositoryCoordinator();
    owner.configure(
      keys: keys,
      supportRoot: () async => root,
      deleteDirectory: (_) async {
        final dir = Directory('${root.path}/offline_repo');
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      },
    );
    const format = SnapshotObjectFormat.sha1;
    final entries = <SnapshotTreeEntry>[];
    Future<void> blob(
      String path,
      List<int> content,
      SnapshotContentKind? kind, {
      SnapshotEntryState state = SnapshotEntryState.saved,
    }) async {
      final id = gitBlobId(content, 'sha1');
      final saved = state == SnapshotEntryState.saved;
      if (saved) {
        await store.writeBlob(format, id, content, mayCommit: () => true);
      }
      entries.add(
        SnapshotTreeEntry(
          path: path,
          type: SnapshotEntryType.blob,
          mode: '100644',
          id: id,
          state: state,
          kind: saved ? kind : null,
          size: saved ? content.length : null,
        ),
      );
    }

    void tree(String path) => entries.add(
      SnapshotTreeEntry(
        path: path,
        type: SnapshotEntryType.tree,
        mode: '040000',
        id: gitBlobId(utf8.encode(path), 'sha1'),
        state: SnapshotEntryState.saved,
      ),
    );

    tree('docs');
    tree('src');
    await blob('README.md', utf8.encode(_readme), SnapshotContentKind.text);
    await blob('docs/a.png', _png, SnapshotContentKind.image);
    await blob(
      'docs/missing.png',
      [1, 2, 3],
      null,
      state: SnapshotEntryState.missing,
    );
    await blob(
      'src/main.dart',
      utf8.encode('void main() {}\n// second line\nfinal third = 3;\n'),
      SnapshotContentKind.text,
    );
    await blob('bin.dat', [0, 1, 2], null, state: SnapshotEntryState.binary);
    await blob(
      '.gitattributes',
      utf8.encode('*.dat binary\n* text=auto eol=lf\n'),
      SnapshotContentKind.text,
    );
    final record = SnapshotRecord(
      id: _id,
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
      committedAt: _date,
      status: SnapshotStatus.complete,
      createdAt: _date,
      savedAt: _date,
      entryCount: entries.length,
      savedCount: 4,
      notSaved: const {
        SnapshotEntryState.missing: 1,
        SnapshotEntryState.binary: 1,
      },
      storedBytes: 4096,
      headSha: headSha,
      probe: probe,
    );
    await store.writeTree(
      SnapshotTree(snapshotId: _id, sha: _sha, subPath: '', entries: entries),
      format: format,
      complete: true,
      mayCommit: () => true,
    );
    // A complete record must point at a readable tree before it is indexed.
    for (final extra in more) {
      if (extra.status != SnapshotStatus.complete) continue;
      await store.writeTree(
        SnapshotTree(snapshotId: extra.id, sha: extra.sha, subPath: '', entries: []),
        format: format,
        complete: true,
        mayCommit: () => true,
      );
    }
    await store.writeIndex(
      SnapshotIndex(
        accountKey: _account.key,
        lastValidatedAt: _date,
        consentAt: _date,
        lastProbeAt: _date,
        snapshots: [record, ...more],
      ),
      expectedRevision: store.revision,
      mayCommit: () => true,
    );
    if (open) owner.open(_binding, readOnly: readOnly);
    return _Snap(root, keys, owner, store, record);
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Future<OfflineRepositories> _adapter(
  WidgetTester tester,
  _Snap snap, {
  GitLabApi? api,
  DiskBinding? binding,
}) async {
  late OfflineRepositories repositories;
  await tester.runAsync(() async {
    repositories = OfflineRepositories(
      binding: binding ?? _binding,
      coordinator: snap.owner,
      api: api,
    );
    await repositories.refresh();
  });
  addTearDown(repositories.dispose);
  return repositories;
}

Widget _app(
  Widget home, {
  NetworkBoundaryMode mode = NetworkBoundaryMode.offlineSnapshot,
  OfflineRepositories? repositories,
}) {
  Widget app = MaterialApp(home: home);
  if (repositories != null) {
    app = OfflineScope(repositories: repositories, account: _account, child: app);
  }
  return NetworkBoundary(mode: mode, child: app);
}

Future<void> _until(WidgetTester tester, Finder finder, {String? what}) =>
    pumpUntil(
      tester,
      () => finder.evaluate().isNotEmpty,
      maxCycles: 200,
      description: what ?? finder.toString(),
    );

/// Every snapshot image settled: no spinner remains (so pumpAndSettle ends).
Future<void> _imagesSettled(WidgetTester tester) => pumpUntil(
  tester,
  () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
  maxCycles: 200,
  description: 'snapshot images settled',
);

SnapshotRecord _record(
  String id, {
  SnapshotStatus status = SnapshotStatus.complete,
  SnapshotFailure? failure,
  bool interrupted = false,
  String? headSha,
  SnapshotProbe? probe,
  Map<SnapshotEntryState, int> notSaved = const {},
  SnapshotRefKind refKind = SnapshotRefKind.branch,
}) => SnapshotRecord(
  id: id,
  projectId: 50 + id.codeUnitAt(31) % 40,
  projectPath: 'group/p$id',
  projectName: 'P ${id.substring(28)}',
  defaultBranch: 'main',
  refKind: refKind,
  refName: refKind == SnapshotRefKind.tag ? 'v1.0' : 'main',
  sha: _sha,
  objectFormat: SnapshotObjectFormat.sha1,
  subPath: '',
  commitTitle: 'title',
  committedAt: _date,
  status: status,
  createdAt: _date,
  savedAt: status == SnapshotStatus.complete ? _date : null,
  failure: failure,
  interrupted: interrupted,
  headSha: headSha,
  probe: probe,
  notSaved: notSaved,
  storedBytes: 1024,
);

void main() {
  late _FakeLauncher launcher;
  late _FakeShare sharer;
  late UrlLauncherPlatform originalLauncher;
  late SharePlatform originalShare;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    launcher = _FakeLauncher();
    sharer = _FakeShare();
    originalLauncher = UrlLauncherPlatform.instance;
    originalShare = SharePlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    SharePlatform.instance = sharer;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
    SharePlatform.instance = originalShare;
  });

  group('zero outbound in offlineSnapshot mode', () {
    testWidgets('README, images, links and a file preview send nothing', (
      tester,
    ) async {
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
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final adapter = FakeAdapter((_) => jsonResponse({}, status: 500));
      final api = testApi(adapter, host: _host);
      addTearDown(api.close);
      final repositories = await _adapter(tester, snap, api: api);
      final reader = repositories.reader(repositories.snapshots.single);
      await tester.pumpWidget(
        _app(
          SnapshotBrowserPage(
            repositories: repositories,
            record: repositories.snapshots.single,
            reader: reader,
            account: _account,
          ),
          repositories: repositories,
        ),
      );
      await _until(tester, find.byKey(const ValueKey('snapshot-readme')));
      await _until(tester, find.byKey(const ValueKey('snapshot-image')));
      await _until(tester, find.text('此圖片未保存'));
      await _imagesSettled(tester);
      // The header names the ref, the short SHA and the date.
      expect(
        find.textContaining('離線版本 · main @ aaaaaaaa · 保存於 2026/10/28'),
        findsOneWidget,
      );
      // Unsaved files are muted and say why; the attributes hint shows.
      expect(find.text('二進位檔'), findsOneWidget);
      expect(find.byKey(const ValueKey('snapshot-attributes-hint')), findsOneWidget);
      // One legitimate image; uploads, external, other project, other ref
      // and the unsaved image are placeholders.
      expect(find.byKey(const ValueKey('snapshot-image')), findsOneWidget);
      expect(find.text('離線時不載入'), findsNWidgets(3));
      expect(find.text('此圖片未保存'), findsOneWidget);

      // An outside link only offers its address to copy.
      await tester.ensureVisible(find.text('site', findRichText: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('site', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('snapshot-link-sheet')), findsOneWidget);
      expect(find.text('https://outside.example.org/page'), findsOneWidget);
      expect(find.text('開啟'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('snapshot-link-copy')));
      await tester.pumpAndSettle();
      expect(find.text('已複製'), findsOneWidget);
      expect(clipboard, hasLength(1), reason: 'the clipboard is the only way out');
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();

      // A link into the same snapshot opens the file locally.
      await tester.ensureVisible(find.text('code', findRichText: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('code', findRichText: true));
      await _until(tester, find.byKey(const ValueKey('snapshot-file-line-2')));
      // Let the page transition finish before tapping its app bar.
      await tester.pumpAndSettle();
      expect(find.text('// second line'), findsOneWidget);
      // No share, refresh, AI, history or edit on a snapshot file.
      expect(find.byType(ResourceShareButton), findsNothing);
      await tester.tap(find.byKey(const ValueKey('snapshot-file-actions')));
      await tester.pumpAndSettle();
      expect(find.text('重新載入'), findsNothing);
      expect(find.text('檔案歷史'), findsNothing);
      expect(find.text('關閉自動換行'), findsOneWidget);
      await tester.tap(find.text('關閉自動換行'));
      await tester.pumpAndSettle();

      expect(adapter.requests, isEmpty, reason: 'no GitLabApi call');
      expect(launcher.calls, 0);
      expect(sharer.calls, 0);
    });

    testWidgets('MarkdownView(snapshot) uses neither the API nor the external client', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final adapter = FakeAdapter((_) => jsonResponse({}, status: 500));
      final api = testApi(adapter, host: _host);
      addTearDown(api.close);
      final external = FakeAdapter((_) => ResponseBody.fromBytes(_png, 200));
      final repositories = await _adapter(tester, snap);
      final reader = repositories.reader(repositories.snapshots.single);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SingleChildScrollView(
              child: MarkdownView(
                '$_readme\n![upload](/uploads/0123456789abcdef0123456789abcdef/f.png)\n',
                account: _account,
                api: api,
                externalMediaClient: Dio()..httpClientAdapter = external,
                base: _account.instance.projectWeb(
                  'group/project/-/blob/$_sha/README.md',
                ),
                projectId: 42,
                projectWeb: _account.instance.projectWeb('group/project'),
                projectPath: 'group/project',
                snapshot: SnapshotMarkdownContext(
                  reader: reader,
                  projectPath: 'group/project',
                  refName: 'main',
                ),
              ),
            ),
          ),
        ),
      );
      await _until(tester, find.byKey(const ValueKey('snapshot-image')));
      await _until(tester, find.text('此圖片未保存'));
      await _imagesSettled(tester);
      expect(find.text('離線時不載入'), findsNWidgets(4));
      await tester.tap(find.text('site', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('snapshot-link-sheet')), findsOneWidget);
      expect(adapter.requests, isEmpty);
      expect(external.requests, isEmpty);
      expect(launcher.calls, 0);
      expect(sharer.calls, 0);
    });

    testWidgets('online, snapshot images still come from the snapshot only', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final adapter = FakeAdapter((_) => ResponseBody.fromBytes(_png, 200));
      final api = testApi(adapter, host: _host);
      addTearDown(api.close);
      final repositories = await _adapter(tester, snap);
      final reader = repositories.reader(repositories.snapshots.single);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: MarkdownView(
              '![ok](docs/a.png)\n![gone](docs/missing.png)\n',
              account: _account,
              api: api,
              base: _account.instance.projectWeb(
                'group/project/-/blob/$_sha/README.md',
              ),
              projectId: 42,
              projectWeb: _account.instance.projectWeb('group/project'),
              snapshot: SnapshotMarkdownContext(
                reader: reader,
                projectPath: 'group/project',
                refName: 'main',
              ),
            ),
          ),
          mode: NetworkBoundaryMode.online,
        ),
      );
      await _until(tester, find.byKey(const ValueKey('snapshot-image')));
      await _until(tester, find.text('此圖片未保存'));
      expect(adapter.requests, isEmpty, reason: 'never api.rawFileBytes');
    });

    testWidgets('media that arrives after the account was fenced is not shown', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      final reader = repositories.reader(repositories.snapshots.single);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: MarkdownView(
              '![ok](docs/a.png)\n',
              account: _account,
              base: _account.instance.projectWeb(
                'group/project/-/blob/$_sha/README.md',
              ),
              projectId: 42,
              projectWeb: _account.instance.projectWeb('group/project'),
              snapshot: SnapshotMarkdownContext(
                reader: reader,
                projectPath: 'group/project',
                refName: 'main',
              ),
            ),
          ),
        ),
      );
      // Switching accounts fences the departing account synchronously.
      snap.owner.fence(_account.key);
      await _until(tester, find.byKey(const ValueKey('snapshot-media-placeholder')));
      expect(find.byKey(const ValueKey('snapshot-image')), findsNothing);
    });

    testWidgets('the boundary refuses the browser and the share sheet', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => openExternal(
                      context,
                      Uri.parse('https://example.test/group/project'),
                    ),
                    child: const Text('open'),
                  ),
                  ResourceShareButton(
                    uri: Uri.parse('https://example.test/group/project'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(find.text('離線時無法開啟'), findsOneWidget);
      await tester.tap(find.byType(ResourceShareButton));
      await tester.pump();
      expect(launcher.calls, 0);
      expect(sharer.calls, 0);
    });
  });

  group('AI regression', () {
    testWidgets('MarkdownView(offline: true) keeps its placeholder and confirmed links', (
      tester,
    ) async {
      final external = FakeAdapter((_) => ResponseBody.fromBytes(_png, 200));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownView(
              '![chart](https://cdn.example.org/chart.png)\n\n[docs](https://docs.example.org/a)\n',
              externalMediaClient: Dio()..httpClientAdapter = external,
              offline: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(l10n.markdownOfflineMedia), findsOneWidget);
      expect(find.byKey(const ValueKey('snapshot-media-placeholder')), findsNothing);
      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.markdownOpenLinkTitle), findsOneWidget);
      expect(launcher.calls, 0);
      await tester.tap(find.text(l10n.open));
      await tester.pumpAndSettle();
      expect(launcher.calls, 1, reason: 'unchanged: confirmed links still open');
      expect(external.requests, isEmpty);
    });
  });

  group('status chip', () {
    final statuses = [
      const SnapshotRowStatus(SnapshotStatusKind.saved),
      const SnapshotRowStatus(SnapshotStatusKind.savedPartial, notSaved: 3),
      const SnapshotRowStatus(SnapshotStatusKind.saving, percent: 42),
      const SnapshotRowStatus(SnapshotStatusKind.queued),
      const SnapshotRowStatus(SnapshotStatusKind.waitingBudget),
      const SnapshotRowStatus(SnapshotStatusKind.waitingRateLimit),
      const SnapshotRowStatus(SnapshotStatusKind.paused),
      const SnapshotRowStatus(SnapshotStatusKind.interrupted),
      for (final failure in SnapshotFailure.values)
        SnapshotRowStatus(SnapshotStatusKind.failed, failure: failure),
      const SnapshotRowStatus(SnapshotStatusKind.newer),
      const SnapshotRowStatus(SnapshotStatusKind.branchGone),
      const SnapshotRowStatus(SnapshotStatusKind.tagGone),
      const SnapshotRowStatus(SnapshotStatusKind.commitGone),
    ];

    testWidgets('every state is an icon plus a label', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [for (final s in statuses) SnapshotStatusChip(s)],
              ),
            ),
          ),
        ),
      );
      // Independent expected texts: the chip must not be checked against the
      // same function that renders it.
      for (final label in const [
        '已保存',
        '已保存 · 3 個未保存',
        '保存中 42%',
        '排隊中',
        '等待額度',
        '等待限流解除',
        '已暫停',
        '已中斷',
        '有新版本',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('保存中 42%'), findsOneWidget);
      expect(
        find.text(
          '失敗：這個 GitLab 伺服器要求不要保存它的回應，所以無法離線保存這個專案。',
        ),
        findsOneWidget,
      );
      expect(find.text('分支已不存在'), findsOneWidget);
      expect(find.text('標籤已不存在'), findsOneWidget);
      expect(find.text('保存的提交已不在 GitLab 上'), findsOneWidget);
      expect(find.byType(Icon), findsNWidgets(statuses.length));
    });

    for (final tag in ['de', 'ar', 'zh-TW']) {
      testWidgets('320 dp at 2x text in $tag has no overflow', (tester) async {
        useLanguage(languageForTag(tag)!);
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: Directionality(
                textDirection: languageForTag(tag)!.rtl
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                child: child!,
              ),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [for (final s in statuses) SnapshotStatusChip(s)],
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('derived status', () {
    test('records and jobs map to the §6.4 states', () {
      expect(recordStatus(_record('0' * 31 + '1'), null).kind, SnapshotStatusKind.saved);
      expect(
        recordStatus(
          _record('0' * 31 + '2', notSaved: {SnapshotEntryState.binary: 2}),
          null,
        ).notSaved,
        2,
      );
      expect(
        recordStatus(_record('0' * 31 + '3', headSha: 'b' * 40), null).kind,
        SnapshotStatusKind.newer,
      );
      expect(
        recordStatus(_record('0' * 31 + '4', probe: SnapshotProbe.refGone), null).kind,
        SnapshotStatusKind.branchGone,
      );
      expect(
        recordStatus(
          _record('0' * 31 + '5', probe: SnapshotProbe.refGone, refKind: SnapshotRefKind.tag),
          null,
        ).kind,
        SnapshotStatusKind.tagGone,
      );
      expect(
        recordStatus(_record('0' * 31 + '6', probe: SnapshotProbe.commitGone), null).kind,
        SnapshotStatusKind.commitGone,
      );
      expect(
        recordStatus(_record('0' * 31 + '7', status: SnapshotStatus.paused), null).kind,
        SnapshotStatusKind.paused,
      );
      expect(
        recordStatus(
          _record('0' * 31 + '8', status: SnapshotStatus.paused, interrupted: true),
          null,
        ).kind,
        SnapshotStatusKind.interrupted,
      );
      expect(
        recordStatus(_record('0' * 31 + '9', status: SnapshotStatus.saving), null).kind,
        SnapshotStatusKind.interrupted,
      );
      final failed = recordStatus(
        _record('0' * 30 + '10', status: SnapshotStatus.failed, failure: SnapshotFailure.deviceFull),
        null,
      );
      expect(failed.kind, SnapshotStatusKind.failed);
      expect(snapshotStatusLabel(failed).$2, '失敗：裝置的儲存空間不足。');
      // A rate-limit wait names minutes only when the reset is known.
      expect(snapshotPhaseText(const SnapshotRowStatus(SnapshotStatusKind.waitingRateLimit)), isNull);
      expect(
        snapshotPhaseText(
          SnapshotRowStatus(
            SnapshotStatusKind.waitingRateLimit,
            retryAt: DateTime.now().add(const Duration(minutes: 3)),
          ),
        ),
        '約 3 分鐘後自動繼續',
      );
    });
  });

  group('consent explainer', () {
    testWidgets('asks before the first save and records the time', (tester) async {
      DateTime? result;
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showOfflineConsent(context, username: 'coder');
                done = true;
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('離線保存前請先了解'), findsOneWidget);
      expect(find.textContaining('@coder'), findsOneWidget);
      expect(find.textContaining('30 天的上限不是撤銷機制'), findsOneWidget);
      expect(find.textContaining('force-push'), findsOneWidget);
      expect(find.textContaining('App 鎖定'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(result, isNull);
      done = false;
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('offline-consent-save')));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
    });

    testWidgets('reopened from the sheet it only closes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showOfflineConsent(
                context,
                username: 'coder',
                forSave: false,
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offline-consent-save')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('offline-consent-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('offline-consent')), findsNothing);
    });
  });

  group('save sheet', () {
    final project = Project(
      id: 42,
      name: 'Project',
      path: 'group/project',
      defaultBranch: 'main',
    );
    RepositoryRef ref(String sha) => RepositoryRef(
      kind: RepositoryRefKind.branch,
      name: 'main',
      sha: sha,
      protected: false,
    );

    Future<void> pumpSheet(
      WidgetTester tester,
      OfflineRepositories repositories, {
      String sha = _sha,
      String folder = '',
      bool switchedOff = false,
      Size size = const Size(400, 900),
      double scale = 1,
      double keyboard = 0,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: OfflineSaveSheet(
              repositories: repositories,
              account: _account,
              project: project,
              reference: ref(sha),
              folder: folder,
              consentAt: _date,
              cacheSwitchedOff: switchedOff,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('saved at the same commit: up to date, open offline version', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      await pumpSheet(tester, repositories);
      expect(find.byKey(const ValueKey('offline-save-current')), findsOneWidget);
      expect(find.byKey(const ValueKey('offline-save-open')), findsOneWidget);
      expect(find.text('已保存 · 2 個未保存'), findsOneWidget);
      expect(find.textContaining('只屬於 @coder'), findsOneWidget);
      expect(find.textContaining(' / 600.0 MB'), findsOneWidget);
    });

    testWidgets('a newer commit offers the update; read-only storage blocks it', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      await pumpSheet(tester, repositories, sha: 'c' * 40);
      expect(find.text('更新到最新版本'), findsOneWidget);
      // No live client for this binding: the button says why it is off.
      expect(find.byKey(const ValueKey('offline-save-blocker')), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('offline-save-start')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('a folder is preselected; the switch being off blocks saving', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      await pumpSheet(tester, repositories, folder: 'docs', switchedOff: true);
      final folder = tester.widget<ListTile>(
        find.byKey(const ValueKey('offline-scope-folder')),
      );
      expect(folder.selected, isTrue);
      expect(find.text('離線快取已關閉。'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('offline-scope-all')));
      await tester.pump();
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('offline-scope-all'))).selected,
        isTrue,
      );
    });

    testWidgets('unavailable secure storage blocks saving', (tester) async {
      final snap = await tester.runAsync(() => _Snap.create(open: false));
      addTearDown(snap!.dispose);
      await tester.runAsync(() async {
        snap.keys.unavailable = true;
        snap.owner.open(_binding);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      final repositories = await _adapter(tester, snap);
      await pumpSheet(tester, repositories);
      expect(find.text('安全儲存區暫時無法使用。'), findsOneWidget);
    });

    testWidgets('ready: GitLab rate limiting blocks with minutes only when known', (
      tester,
    ) async {
      final snap = await tester.runAsync(() => _Snap.create(open: false));
      addTearDown(snap!.dispose);
      final adapter = FakeAdapter((_) => jsonResponse({}, status: 500));
      final api = testApi(adapter, host: _host);
      addTearDown(api.close);
      api.bindReadCache(_account.key, 1);
      // Rate limited before the adapter exists, so its opening probe waits.
      // On the real loop: the cooldown's expiry timer is not the test's.
      await tester.runAsync(() async {
        api.rateBudget.noteResponse(
          headers: {
            'retry-after': ['600'],
          },
          statusCode: 429,
          requestClass: RateRequestClass.global,
          sequence: api.rateBudget.nextSequence(),
          trusted: true,
        );
        snap.owner.open(_binding);
        // Opening recovers under the maintenance lock; wait for it here.
        await snap.owner.snapshots(_binding);
      });
      final repositories = await _adapter(tester, snap, api: api);
      await pumpSheet(tester, repositories, sha: 'c' * 40);
      expect(find.textContaining('GitLab 正在限制請求'), findsOneWidget);
      expect(find.textContaining('分鐘後可以再試'), findsOneWidget);
      // Reading the cooldown arms its expiry timer; closing cancels it.
      await tester.pumpWidget(const SizedBox());
      api.rateBudget.close();
    });

    for (final tag in ['de', 'ar']) {
      testWidgets('320 dp, 2x text and the keyboard up in $tag', (tester) async {
        useLanguage(languageForTag(tag)!);
        final snap = await tester.runAsync(_Snap.create);
        addTearDown(snap!.dispose);
        final repositories = await _adapter(tester, snap);
        await pumpSheet(
          tester,
          repositories,
          sha: 'c' * 40,
          folder: 'docs/very/deep/folder/name',
          size: const Size(320, 640),
          scale: 2,
          keyboard: 280,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('offline projects page', () {
    testWidgets('rows, states, delete and delete all', (tester) async {
      final snap = await tester.runAsync(
        () => _Snap.create(
          more: [
            _record('0' * 31 + 'b', status: SnapshotStatus.failed, failure: SnapshotFailure.versionGone),
            _record('0' * 31 + 'c', status: SnapshotStatus.paused, interrupted: true),
            _record('0' * 31 + 'd', probe: SnapshotProbe.commitGone),
          ],
        ),
      );
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      await tester.pumpWidget(
        _app(
          OfflineProjectsPage(repositories: repositories, account: _account),
          repositories: repositories,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('offline-projects-header')), findsOneWidget);
      expect(find.textContaining('4 個專案 · 已使用 '), findsOneWidget);
      expect(find.text('已保存 · 2 個未保存'), findsOneWidget);
      expect(find.text('失敗：這個版本已不在 GitLab 上。'), findsOneWidget);
      expect(find.text('已中斷'), findsOneWidget);
      expect(find.text('保存的提交已不在 GitLab 上'), findsOneWidget);
      expect(find.text('全部刪除離線專案'), findsOneWidget);

      // Delete one: confirm with name and size; GitLab is not affected.
      await tester.tap(find.byKey(const ValueKey('offline-row-menu-$_id')));
      await tester.pumpAndSettle();
      expect(find.text('在線上開啟'), findsNothing, reason: 'offline');
      expect(find.text('更新'), findsNothing, reason: 'offline');
      await tester.tap(find.text('刪除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Project'), findsWidgets);
      expect(find.textContaining('4.0 KB'), findsWidgets);
      await tester.tap(find.text('確認'));
      await pumpUntil(
        tester,
        () =>
            repositories.snapshots.every((s) => s.id != _id) &&
            !repositories.loading,
        maxCycles: 200,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('已保存 · 2 個未保存'), findsNothing);

      // Delete all: the count and the size are in the question.
      await tester.tap(find.byKey(const ValueKey('offline-delete-all')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('3 個離線專案'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(repositories.snapshots, hasLength(3));
    });

    testWidgets('a non-empty list at 320 dp and 2x in ar has no overflow', (
      tester,
    ) async {
      useLanguage(languageForTag('ar')!);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final snap = await tester.runAsync(
        () => _Snap.create(
          more: [
            _record('0' * 31 + 'b', status: SnapshotStatus.failed, failure: SnapshotFailure.serverForbidsStorage),
          ],
        ),
      );
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      await tester.pumpWidget(
        _app(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: OfflineProjectsPage(
                repositories: repositories,
                account: _account,
              ),
            ),
          ),
          repositories: repositories,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('no offline projects shows the empty state', (tester) async {
    final owner = OfflineRepositoryCoordinator()
      ..configure(
        keys: fixture.MemoryKeys()..value = null,
        supportRoot: () async => Directory.systemTemp,
        deleteDirectory: (_) async {},
      );
    late OfflineRepositories repositories;
    await tester.runAsync(() async {
      owner.open(_binding, readOnly: true);
      repositories = OfflineRepositories(binding: _binding, coordinator: owner);
      await repositories.refresh();
    });
    addTearDown(repositories.dispose);
    await tester.pumpWidget(
      _app(
        OfflineProjectsPage(repositories: repositories, account: _account),
        repositories: repositories,
      ),
    );
    await tester.pump();
    expect(repositories.snapshots, isEmpty);
    expect(find.text('還沒有離線專案'), findsOneWidget);
    expect(find.byKey(const ValueKey('offline-delete-all')), findsNothing);
  });

  group('leaving the session', () {
    // FIX1 P1-2: an inventory that is loading or failed is never zero.
    Future<bool? Function()> leaveButton(
      WidgetTester tester,
      OfflineRepositories repositories,
    ) async {
      bool? answer;
      var done = false;
      await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    answer = await confirmOfflineLoss(
                      context,
                      repositories: repositories,
                      account: _account,
                      kind: LeaveKind.switchAccount,
                    );
                    done = true;
                  },
                  child: const Text('leave'),
                ),
              ),
            ),
            repositories: repositories,
            mode: NetworkBoundaryMode.online,
          ),
      );
      return () => done ? answer : null;
    }

    testWidgets('an inventory still loading is awaited, then counted', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      late OfflineRepositories repositories;
      await tester.runAsync(() async {
        // Completers made on the real loop resolve there, not on the widget
        // clock that runAsync does not pump.
        snap.keys
          ..readGate = Completer<void>()
          ..readStarted = Completer<void>();
        repositories = OfflineRepositories(
          binding: _binding,
          coordinator: snap.owner,
        );
        // The inventory is held in the middle of reading the key.
        await snap.keys.readStarted!.future;
      });
      addTearDown(repositories.dispose);
      expect(repositories.loading, isTrue);
      expect(repositories.snapshots, isEmpty, reason: 'not loaded is not zero');
      final result = await leaveButton(tester, repositories);
      await tester.tap(find.text('leave'));
      await tester.pump();
      expect(find.text('要刪除離線專案嗎？'), findsNothing, reason: 'waits for the count');
      expect(result(), isNull, reason: 'nothing decided yet');
      await tester.runAsync(() async {
        snap.keys.readGate!.complete();
        while (repositories.loading) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await _until(
        tester,
        find.textContaining('切換帳號會刪除 @coder 的 1 個離線專案（'),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result(), isFalse);
    });

    testWidgets('an inventory that does not finish in time asks with an unknown count', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      late Completer<void> gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      late OfflineRepositories repositories;
      await tester.runAsync(() async {
        gate = Completer<void>();
        snap.keys
          ..readGate = gate
          ..readStarted = Completer<void>();
        repositories = OfflineRepositories(
          binding: _binding,
          coordinator: snap.owner,
        );
        await snap.keys.readStarted!.future;
      });
      addTearDown(repositories.dispose);
      final result = await leaveButton(tester, repositories);
      await tester.tap(find.text('leave'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
        find.text('切換帳號會刪除 @coder 在這台裝置上的所有離線專案；目前無法確認有幾個。'),
        findsOneWidget,
      );
      await tester.tap(find.text('繼續並刪除'));
      await tester.pumpAndSettle();
      expect(result(), isTrue);
    });

    testWidgets('a failed inventory asks with an unknown count', (tester) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      snap.keys.unavailable = true;
      final repositories = await _adapter(tester, snap);
      expect(repositories.state, OfflineRepositoryState.unavailable);
      expect(repositories.failure, isNotNull);
      expect(repositories.snapshots, isEmpty);
      final result = await leaveButton(tester, repositories);
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      expect(
        find.text('切換帳號會刪除 @coder 在這台裝置上的所有離線專案；目前無法確認有幾個。'),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result(), isFalse);
    });

    testWidgets('lists the count and size; none means no question', (
      tester,
    ) async {
      final snap = await tester.runAsync(_Snap.create);
      addTearDown(snap!.dispose);
      final repositories = await _adapter(tester, snap);
      bool? answer;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => answer = await confirmOfflineLoss(
                  context,
                  repositories: OfflineScope.maybeOf(context, listen: false),
                  account: _account,
                  kind: LeaveKind.switchAccount,
                ),
                child: const Text('leave'),
              ),
            ),
          ),
          repositories: repositories,
          mode: NetworkBoundaryMode.online,
        ),
      );
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      expect(find.text('要刪除離線專案嗎？'), findsOneWidget);
      expect(find.textContaining('切換帳號會刪除 @coder 的 1 個離線專案（'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('繼續並刪除'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);

      await tester.runAsync(repositories.clearAll);
      await tester.pump();
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      expect(find.text('要刪除離線專案嗎？'), findsNothing);
      expect(answer, isTrue);
    });

    testWidgets('endSessionFrom and the account sheet run through the scope', (
      tester,
    ) async {
      final intents = <LeaveKind>[];
      var ran = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SessionLeaveScope(
            leave: (intent, action) async {
              intents.add(intent.kind);
            },
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => SessionLeaveScope.run(
                  context,
                  const LeaveIntent(LeaveKind.signOut),
                  () async => ran++,
                ),
                child: const Text('leave'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('leave'));
      await tester.pump();
      expect(intents, [LeaveKind.signOut]);
      expect(ran, 0, reason: 'the scope decides whether the action runs');
    });
  });

  testWidgets('the not-saved sheet explains offline and the filter is local', (
    tester,
  ) async {
    final snap = await tester.runAsync(_Snap.create);
    addTearDown(snap!.dispose);
    final repositories = await _adapter(tester, snap);
    await tester.pumpWidget(
      _app(
        SnapshotBrowserPage(
          repositories: repositories,
          record: repositories.snapshots.single,
          reader: repositories.reader(repositories.snapshots.single),
          account: _account,
        ),
        repositories: repositories,
      ),
    );
    await _until(tester, find.byKey(const ValueKey('snapshot-row-bin.dat')));
    await tester.tap(find.byKey(const ValueKey('snapshot-row-bin.dat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('snapshot-not-saved-sheet')), findsOneWidget);
    expect(find.text('連線時可以開啟線上版本。'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('snapshot-filter')), 'main');
    await tester.pump();
    expect(find.byKey(const ValueKey('snapshot-row-src/main.dart')), findsOneWidget);
    expect(find.byKey(const ValueKey('snapshot-row-README.md')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('snapshot-filter')), 'zzz');
    await tester.pump();
    expect(find.text('沒有符合的檔案'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('snapshot-filter')), '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('snapshot-row-docs')));
    await tester.pump();
    expect(find.byKey(const ValueKey('snapshot-row-docs/a.png')), findsOneWidget);
    expect(find.text('封存檔中沒有'), findsOneWidget);
    expect(launcher.calls, 0);
  });
}
