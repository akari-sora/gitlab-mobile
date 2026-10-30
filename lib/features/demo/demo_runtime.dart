import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../ai/ai_history.dart';
import '../ai/ai_journal_key_store.dart';
import '../ai/ai_run_registry.dart';
import '../ai/ai_scope.dart';
import '../ai/ai_settings_provider.dart';
import '../ai/ai_stores.dart';
import '../ai/ai_write_journal.dart';
import '../auth/session_controller.dart';
import '../cache/read_cache_disk_coordinator.dart';
import '../shell/app_shortcuts.dart';
import '../shell/appearance.dart';
import '../shell/language.dart';
import 'demo_ai.dart';
import 'demo_data.dart';
import 'demo_scope.dart';
import 'demo_server.dart';
import 'demo_stores.dart';

/// Everything one demo visit owns, isolated from the device's state:
///
/// * its own [SessionController] over an in-memory account store, with a
///   read-cache coordinator in a private, unconfigured domain (so it never
///   claims the app's startup session and offline saving is unavailable);
/// * a [GitLabApi] whose only transport is [DemoGitLabAdapter];
/// * in-memory recent projects, launcher host and appearance;
/// * when AI is on, an AI settings owner over its own [MemoryAiStore] (never
///   the device's provider list), a history coordinator that has no disk, and
///   a write journal kept in memory.
///
/// [dispose] drops all of it.
final class DemoRuntime {
  DemoRuntime._({
    required this.server,
    required this.account,
    required this.session,
    required this.offline,
    required this.shortcuts,
    required this.appearance,
    required this.container,
    required this.journal,
    this.ai,
    this.aiSessionFactory,
  });

  /// Builds a demo visit. [ai] follows the app's AI gate. [appearance] is the
  /// device's current appearance record, which the demo starts from.
  static Future<DemoRuntime> start({
    required bool ai,
    String? appearance,
    LanguageController? language,
  }) async {
    final server = DemoGitLabServer();
    final adapter = DemoGitLabAdapter(server);
    final user = demoUser(demoUserId);
    final account = Account(
      instance: demoInstance,
      user: GitLabUser(
        id: demoUserId,
        username: user['username'] as String,
        name: user['name'] as String,
      ),
      token: _token,
    );
    final api = GitLabApi(
      instance: demoInstance,
      token: _token,
      dio: Dio()..httpClientAdapter = adapter,
      cdnAdapter: adapter,
      forbiddenDetail: () => l10n.demoWriteRefused,
    );
    final session =
        SessionController(
            DemoAccountStore(account),
            readCache: ReadCacheDiskCoordinator(coordinationScope: Object()),
          )
          ..active = account
          ..api = api
          ..initializing = false;
    final shortcuts = LauncherShortcuts(
      DemoShortcutHost(),
      DemoRecentProjectStore(),
    )..bind(account.key);
    unawaited(shortcuts.start());
    final appearanceController = AppearanceController(
      DemoAppearanceStore(appearance),
    );
    await appearanceController.load();

    // The shell reads start-up recovery notices from it even without AI,
    // so the demo never asks the device's journal about its account.
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: Directory.systemTemp,
      files: DemoJournalFiles(),
    );
    await journal.recoverAfterAccountsLoaded([account.key]);
    AiControllers? controllers;
    AiChatSessionFactory? factory;
    if (ai) {
      try {
        final store = MemoryAiStore();
        final settings = AiSettingsController(store);
        await settings.initialize();
        await settings.saveProvider(demoAiProvider());
        await settings.loadAccount(account.key);
        // Every change waits for the user's approval on a card.
        await settings.setAutonomySettings(
          account.key,
          ceiling: AiAutonomyLevel.confirmEach,
          startingLevel: AiAutonomyLevel.confirmEach,
        );
        final history = AiHistoryCoordinator(
          store: store,
          files: AiHistoryFileStore(root: _noHistoryDirectory),
        );
        await journal.ensureInitialized(account.key);
        controllers = AiControllers(settings: settings, history: history);
        factory = demoAiSessionFactory(journal: journal, history: history);
      } on Object {
        // The demo still works without its assistant.
        controllers = null;
        factory = null;
      }
    }
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(session),
        appearanceProvider.overrideWithValue(appearanceController),
        launcherShortcutsProvider.overrideWithValue(shortcuts),
        if (language != null) languageProvider.overrideWithValue(language),
        if (controllers != null)
          aiSettingsProvider.overrideWithValue(controllers.settings),
      ],
    );
    return DemoRuntime._(
      server: server,
      account: account,
      session: session,
      offline: OfflineRepositoryCoordinator(),
      shortcuts: shortcuts,
      appearance: appearanceController,
      container: container,
      ai: controllers,
      journal: journal,
      aiSessionFactory: factory,
    );
  }

  /// Never sent anywhere: [DemoGitLabAdapter] answers every request.
  static const _token = 'mergeline-demo-offline-sample';

  static Future<Directory> _noHistoryDirectory() async =>
      throw const FileSystemException('The demo keeps no AI history');

  final DemoGitLabServer server;
  final Account account;
  final SessionController session;

  /// An unconfigured owner, so the shell offers no offline saving.
  final OfflineRepositoryCoordinator offline;
  final LauncherShortcuts shortcuts;
  final AppearanceController appearance;

  /// Resolves the app's providers to the demo's own controllers for pages
  /// that read them from the widget tree. It has no parent container.
  final ProviderContainer container;
  final AiControllers? ai;

  /// The demo's AI write journal, kept in memory.
  final AiWriteJournal journal;
  final AiChatSessionFactory? aiSessionFactory;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    shortcuts.dispose();
    appearance.dispose();
    session.dispose();
    ai?.settings.dispose();
    ai?.history.dispose();
  }
}
