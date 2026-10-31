// Issue #56 part 2: first loads that used to show a spinner now show a
// skeleton. For each screen: the skeleton shows while the first read is held,
// goes once it succeeds, a reload keeps the content under the thin bar, a
// retry after a failed first read shows the skeleton again, and the screen
// has one 正在載入 live region (sub-section skeletons inside a loaded page
// have none). Screens whose fixtures live with their own tests are covered
// there: work item types (group_graph_work_items_page_test), analytics cards
// (project_analytics_page_test) and work item attributes
// (work_item_attributes_test).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_log_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_activity.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/main.dart' show StartupScreen;
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _loadingLabel = '正在載入';

/// Exactly one live region announces loading.
void _expectOneLiveRegion(WidgetTester tester) {
  final regions = find.bySemanticsLabel(_loadingLabel);
  expect(regions, findsOneWidget);
  expect(tester.getSemantics(regions).flagsCollection.isLiveRegion, isTrue);
}

/// An [AiStore] over [MemoryAiStore] whose account reads can be held or made
/// to fail, so the settings page's first read can be observed.
final class _GatedAiStore implements AiStore {
  final _inner = MemoryAiStore();
  Completer<void>? hold;
  bool fail = false;

  Future<void> _gate() async {
    if (hold case final gate?) await gate.future;
    if (fail) throw const FileSystemException('synthetic read failure');
  }

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) async {
    await _gate();
    return _inner.loadAccount(accountKey);
  }

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() =>
      _inner.loadProviders();
  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) =>
      _inner.saveProviders(providers);
  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) =>
      _inner.readProviderKey(providerId);
  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) => _inner.readAllProviderKeys(providerIds);
  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) => _inner.saveProviderKey(
    providerId,
    key,
    acknowledgeWarning: acknowledgeWarning,
  );
  @override
  Future<void> deleteProviderKey(String providerId) =>
      _inner.deleteProviderKey(providerId);
  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) =>
      _inner.saveAccount(accountKey, account);
  @override
  Future<List<String>> listAccountKeys() => _inner.listAccountKeys();
  @override
  Future<void> deleteAccount(String accountKey) =>
      _inner.deleteAccount(accountKey);
  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) =>
      _inner.readHistoryKey(accountKey);
  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) =>
      _inner.writeHistoryKey(accountKey, key);
  @override
  Future<void> deleteHistoryKey(String accountKey) =>
      _inner.deleteHistoryKey(accountKey);
  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) =>
      _inner.readTombstone(accountKey);
  @override
  Future<void> setTombstone(String accountKey) =>
      _inner.setTombstone(accountKey);
  @override
  Future<List<String>> listTombstones() => _inner.listTombstones();
  @override
  Future<void> clearTombstone(String accountKey) =>
      _inner.clearTombstone(accountKey);
}

/// A journal key store whose key read can be held.
final class _GatedKeyStore extends MemoryAiJournalKeyStore {
  Completer<void>? hold;

  @override
  Future<AiStoreRead<Uint8List>> readKey(String accountKey) async {
    if (hold case final gate?) await gate.future;
    return super.readKey(accountKey);
  }
}

final class _Fence implements AiJournalAccountFence {
  @override
  bool isCleaning(String accountKey) => false;
  @override
  Future<T> run<T>(String accountKey, Future<T> Function() action) => action();
}

// Work item activity: the smallest GraphQL answer the panel reads.
const _workItemId = 'gid://gitlab/WorkItem/700';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'team/example-42';

final _detail = WorkItemGraphDetail(
  summary: WorkItemGraphSummary(
    id: _workItemId,
    iid: 7,
    title: 'Synthetic work item',
    state: 'OPEN',
    createdAt: DateTime.utc(2026, 10, 1),
    updatedAt: DateTime.utc(2026, 10, 2),
    project: const GraphResourceRef(id: _projectId, fullPath: _path),
    namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
    type: const WorkItemGraphType(
      id: 'gid://gitlab/WorkItems::Type/server-owned',
      name: 'Task',
    ),
  ),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'NOTES'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _activity(String comment) => {
  'data': {
    'currentUser': {'id': 'gid://gitlab/User/7'},
    'workItem': {
      'id': _workItemId,
      'iid': '7',
      'project': {'id': _projectId, 'fullPath': _path},
      'namespace': {'id': _namespaceId, 'fullPath': _path},
      'userPermissions': {'createNote': true},
      'widgets': [
        {
          'type': 'NOTES',
          'discussionLocked': false,
          'discussions': {
            'nodes': [
              {
                'id': 'gid://gitlab/Discussion/1',
                'replyId': 'reply-1',
                'createdAt': '2026-10-01T01:00:00Z',
                'notes': {
                  'nodes': [
                    {
                      'id': 'gid://gitlab/Note/1',
                      'system': false,
                      'systemNoteIconName': null,
                      'body': comment,
                      'createdAt': '2026-10-01T01:02:03Z',
                      'updatedAt': '2026-10-01T01:03:04Z',
                      'author': {
                        'id': 'gid://gitlab/User/9',
                        'name': 'Synthetic User',
                        'username': 'synthetic-user',
                      },
                    },
                  ],
                  'pageInfo': {'hasNextPage': false, 'endCursor': null},
                },
              },
            ],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
      ],
    },
  },
};

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  group('start-up', () {
    testWidgets(
      'stays blank for a fast read, then shows one app-shell skeleton',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(const MaterialApp(home: StartupScreen()));
        expect(find.byType(AppShellSkeleton), findsNothing);
        expect(find.bySemanticsLabel(_loadingLabel), findsNothing);

        await tester.pump(const Duration(milliseconds: 149));
        expect(find.byType(AppShellSkeleton), findsNothing);

        await tester.pump(const Duration(milliseconds: 1));
        expect(find.byType(AppShellSkeleton), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        _expectOneLiveRegion(tester);

        // The fake app bar sits below the status bar, like a real one.
        tester.view.padding = const FakeViewPadding(top: 96);
        addTearDown(tester.view.resetPadding);
        await tester.pump();
        expect(
          tester.getTopLeft(find.byType(AppShellSkeleton)).dy,
          greaterThanOrEqualTo(96 / tester.view.devicePixelRatio),
        );
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('a read that ends inside the delay never shows the skeleton', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: StartupScreen()));
      await tester.pump(const Duration(milliseconds: 100));
      // Accounts loaded: the start-up screen is replaced.
      await tester.pumpWidget(const MaterialApp(home: Text('sign in')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(AppShellSkeleton), findsNothing);
      expect(find.text('sign in'), findsOneWidget);
    });
  });

  group('AI settings', () {
    testWidgets(
      'first read, new account identity and failed first read show the skeleton',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final store = _GatedAiStore()..hold = Completer<void>();
        final settings = AiSettingsController(store);
        final history = AiHistoryCoordinator(store: store);
        Widget page(String account) => MaterialApp(
          home: AiSettingsPage(
            settings: settings,
            history: history,
            accountKey: account,
          ),
        );

        await tester.pumpWidget(page('a'));
        await tester.pump();
        expect(find.byType(SettingsSkeleton), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text(l10n.aiSettingsIntro), findsNothing);
        _expectOneLiveRegion(tester);

        store.hold!.complete();
        store.hold = null;
        await tester.pumpAndSettle();
        expect(find.byType(SettingsSkeleton), findsNothing);
        expect(find.text(l10n.aiSettingsIntro), findsOneWidget);
        expect(find.bySemanticsLabel(_loadingLabel), findsNothing);

        // Another account is another page: its first read shows the skeleton.
        store.hold = Completer<void>();
        await tester.pumpWidget(page('b'));
        await tester.pump();
        expect(find.byType(SettingsSkeleton), findsOneWidget);
        expect(find.text(l10n.aiSettingsIntro), findsNothing);
        store.hold!.complete();
        store.hold = null;
        await tester.pumpAndSettle();
        expect(find.text(l10n.aiSettingsIntro), findsOneWidget);

        // A failed first read, then retry: the skeleton again, not the page.
        store.fail = true;
        await tester.pumpWidget(page('c'));
        await tester.pumpAndSettle();
        expect(find.text(l10n.aiSettingsReadFailure), findsOneWidget);
        expect(find.byType(SettingsSkeleton), findsNothing);
        store
          ..fail = false
          ..hold = Completer<void>();
        await tester.tap(find.text(l10n.retryAction));
        await tester.pump();
        expect(find.byType(SettingsSkeleton), findsOneWidget);
        expect(find.text(l10n.aiSettingsReadFailure), findsNothing);
        _expectOneLiveRegion(tester);
        store.hold!.complete();
        store.hold = null;
        await tester.pumpAndSettle();
        expect(find.byType(SettingsSkeleton), findsNothing);
        expect(find.text(l10n.aiSettingsIntro), findsOneWidget);
        semantics.dispose();
        // The failed read left history retry timers; disposing cancels them.
        await tester.pumpWidget(const SizedBox());
        history.dispose();
        settings.dispose();
      },
    );

    testWidgets('the skeleton starts where the intro and sections start', (
      tester,
    ) async {
      final store = _GatedAiStore()..hold = Completer<void>();
      final settings = AiSettingsController(store);
      final history = AiHistoryCoordinator(store: store);
      addTearDown(settings.dispose);
      addTearDown(history.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: AiSettingsPage(
            settings: settings,
            history: history,
            accountKey: 'a',
          ),
        ),
      );
      await tester.pump();
      final introBone = tester.getTopLeft(
        find
            .descendant(
              of: find.byType(SettingsSkeleton),
              matching: find.byType(SkeletonBone),
            )
            .first,
      );
      final heading = find.descendant(
        of: find.byType(HubSectionSkeleton).first,
        matching: find.byType(SkeletonBone),
      );
      final headingLeft = tester.getTopLeft(heading.first).dx;

      store.hold!.complete();
      store.hold = null;
      await tester.pumpAndSettle();
      final intro = tester.getTopLeft(find.text(l10n.aiSettingsIntro));
      expect(introBone.dx, intro.dx);
      expect((introBone.dy - intro.dy).abs(), lessThanOrEqualTo(6));
      expect(
        headingLeft,
        tester.getTopLeft(find.text(l10n.aiProvidersHeading)).dx,
      );
    });
  });

  group('AI write log', () {
    late Directory root;
    late AiWriteJournal journal;
    late _GatedKeyStore keys;
    final fixture = WorkspaceFixture();
    final account = fixture.account;

    setUp(() {
      root = Directory(
        Directory.systemTemp.resolveSymbolicLinksSync(),
      ).createTempSync('skeleton-write-log-');
      keys = _GatedKeyStore();
      journal = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        fence: _Fence(),
        processId: 'process',
      );
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<void> settle(WidgetTester tester, bool Function() done) =>
        pumpUntil(tester, done, step: const Duration(milliseconds: 20));

    testWidgets(
      'first read, reload under the bar and retry after a failed read',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.runAsync(
          () => journal.recoverAfterAccountsLoaded([account.key]),
        );
        keys.hold = Completer<void>();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            locale: const Locale('zh', 'TW'),
            supportedLocales: const [Locale('zh', 'TW')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: AiWriteLogPage(account: account, journal: journal),
          ),
        );
        await tester.pump();
        expect(find.byType(HubSectionSkeleton), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        _expectOneLiveRegion(tester);

        keys.hold!.complete();
        keys.hold = null;
        await settle(
          tester,
          () => find.text(l10n.aiWriteLogEmpty).evaluate().isNotEmpty,
        );
        expect(find.byType(HubSectionSkeleton), findsNothing);

        // A reset reads the log again afterwards: the empty log stays, under
        // the thin bar, and no skeleton comes back.
        keys.hold = Completer<void>();
        final reset = find.byKey(const ValueKey('ai-write-log-reset'));
        await tester.ensureVisible(reset);
        await tester.pumpAndSettle();
        await tester.tap(reset);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          '@${account.user.username}',
        );
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, l10n.confirmAction));
        await settle(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isNotEmpty,
        );
        expect(find.text(l10n.aiWriteLogEmpty), findsOneWidget);
        expect(find.byType(HubSectionSkeleton), findsNothing);
        keys.hold!.complete();
        keys.hold = null;
        await settle(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        await tester.pump(const Duration(seconds: 5));

        // A failed read, then retry: the skeleton again.
        keys.unavailable = true;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: AiWriteLogPage(account: account, journal: journal),
          ),
        );
        await settle(
          tester,
          () => find.text(l10n.retryAction).evaluate().isNotEmpty,
        );
        expect(find.byType(HubSectionSkeleton), findsNothing);
        keys
          ..unavailable = false
          ..hold = Completer<void>();
        await tester.tap(find.text(l10n.retryAction).first);
        await tester.pump();
        expect(find.byType(HubSectionSkeleton), findsOneWidget);
        _expectOneLiveRegion(tester);
        keys.hold!.complete();
        keys.hold = null;
        await settle(
          tester,
          () => find.byType(HubSectionSkeleton).evaluate().isEmpty,
        );
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('work item activity', () {
    Widget host(GitLabApi api) => MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: WorkItemActivityPanel(
            account: Account(
              instance: api.instance,
              user: const GitLabUser(id: 7, username: 'reader', name: 'Reader'),
              token: 'synthetic-token',
            ),
            api: api,
            detail: _detail,
            project: const Project(id: 42, name: 'Example', path: _path),
          ),
        ),
      ),
    );

    Future<void> expand(WidgetTester tester) async {
      await tester.tap(find.text('活動'));
      await tester.pump();
    }

    testWidgets(
      'first read, reload, failed reload and retry after a failed first read',
      (tester) async {
        final semantics = tester.ensureSemantics();
        Completer<void>? hold;
        var fail = false;
        var comment = 'comment-one';
        ResponseBody answer() => fail
            ? jsonResponse({'message': 'down'}, status: 503)
            : jsonResponse(_activity(comment));
        final api = testApi(
          FakeAdapter((_) async {
            if (hold case final gate?) await gate.future;
            return answer();
          }),
        );
        addTearDown(api.close);

        hold = Completer<void>();
        await tester.pumpWidget(host(api));
        await expand(tester);
        expect(find.byType(ActivityTimelineSkeleton), findsOneWidget);
        _expectOneLiveRegion(tester);
        final gate = hold;
        hold = null;
        gate.complete();
        await settleNetworkWidgets(tester);
        expect(find.byType(ActivityTimelineSkeleton), findsNothing);
        expect(find.textContaining('comment-one'), findsOneWidget);

        // Reload: the thread stays under the thin bar.
        hold = Completer<void>();
        final refresh = find.byKey(
          const ValueKey('work-item-activity-refresh'),
        );
        await tester.ensureVisible(refresh);
        await tester.tap(refresh);
        await tester.pump();
        expect(find.byType(ActivityTimelineSkeleton), findsNothing);
        expect(find.textContaining('comment-one'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        comment = 'comment-two';
        final reload = hold;
        hold = null;
        reload.complete();
        await settleNetworkWidgets(tester);
        expect(find.textContaining('comment-two'), findsOneWidget);
        expect(find.textContaining('comment-one'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);

        // A failed reload keeps the thread and offers retry above it.
        fail = true;
        await tester.ensureVisible(refresh);
        await tester.tap(refresh);
        await settleNetworkWidgets(tester);
        expect(find.textContaining('comment-two'), findsOneWidget);
        expect(find.text(l10n.retryAction), findsOneWidget);
        fail = false;
        comment = 'comment-three';
        await tester.tap(find.text(l10n.retryAction));
        await settleNetworkWidgets(tester);
        expect(find.textContaining('comment-three'), findsOneWidget);
        expect(find.text(l10n.retryAction), findsNothing);

        // A failed first read, then retry: the skeleton again.
        await tester.pumpWidget(const SizedBox());
        fail = true;
        await tester.pumpWidget(host(api));
        await expand(tester);
        await settleNetworkWidgets(tester);
        expect(find.byType(ActivityTimelineSkeleton), findsNothing);
        expect(find.text(l10n.retryAction), findsOneWidget);
        fail = false;
        hold = Completer<void>();
        await tester.tap(find.text(l10n.retryAction));
        await tester.pump();
        expect(find.byType(ActivityTimelineSkeleton), findsOneWidget);
        _expectOneLiveRegion(tester);
        comment = 'comment-four';
        final retry = hold;
        hold = null;
        retry.complete();
        await settleNetworkWidgets(tester);
        expect(find.byType(ActivityTimelineSkeleton), findsNothing);
        expect(find.textContaining('comment-four'), findsOneWidget);
        semantics.dispose();
      },
    );

    testWidgets('a new filter is a new feed and shows the skeleton', (
      tester,
    ) async {
      Completer<void>? hold;
      final api = testApi(
        FakeAdapter((_) async {
          if (hold case final gate?) await gate.future;
          return jsonResponse(_activity('comment-one'));
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(host(api));
      await expand(tester);
      await settleNetworkWidgets(tester);
      expect(find.textContaining('comment-one'), findsOneWidget);

      hold = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('work-item-activity-filter')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('只看留言').last);
      await tester.pump();
      expect(find.byType(ActivityTimelineSkeleton), findsOneWidget);
      expect(find.textContaining('comment-one'), findsNothing);
      final gate = hold;
      hold = null;
      gate.complete();
      await settleNetworkWidgets(tester);
      expect(find.byType(ActivityTimelineSkeleton), findsNothing);
    });
  });

  group('Markdown images', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets(
      'a held image is a box of its declared size with the old label and no live region',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final pending = Completer<ResponseBody>();
        final client = Dio()
          ..httpClientAdapter = FakeAdapter((_) => pending.future);
        addTearDown(client.close);
        await tester.pumpWidget(
          host(
            MarkdownView(
              '<img src="https://images.example/a.png" width="200" height="900">\n\n'
              '![b](https://images.example/b.png)',
              externalMediaClient: client,
            ),
          ),
        );
        await tester.pump();
        final boxes = find.byType(ImageSkeleton);
        expect(boxes, findsNWidgets(2));
        // The declared size, capped at the image's 480 dp height.
        expect(tester.getSize(boxes.first), const Size(200, 480));
        // No declared size: the spinner's old footprint.
        expect(
          tester.getSize(boxes.last),
          const Size.square(ImageSkeleton.fallbackSize),
        );
        expect(find.bySemanticsLabel(l10n.attachmentLoading), findsNWidgets(2));
        expect(find.bySemanticsLabel(_loadingLabel), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);

        pending.complete(
          ResponseBody.fromBytes(
            _png,
            200,
            headers: {
              'content-type': ['image/png'],
            },
          ),
        );
        await settleNetworkWidgets(tester);
        expect(find.byType(ImageSkeleton), findsNothing);
        expect(find.byType(Image), findsWidgets);
        semantics.dispose();
      },
    );
  });
}
