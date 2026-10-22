import 'dart:async';
import 'dart:io';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'core/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/ai/ai_gate.dart';
import 'features/ai/ai_account_cleanup.dart';
import 'features/ai/ai_history.dart';
import 'features/ai/ai_journal_fence.dart';
import 'features/ai/ai_journal_key_store.dart';
import 'features/ai/ai_scope.dart';
import 'features/ai/ai_settings_provider.dart';
import 'features/ai/ai_stores.dart';
import 'features/ai/ai_write_journal.dart';
import 'features/shell/app_shortcuts.dart';
import 'features/auth/session_controller.dart';
import 'features/shell/authenticated_app.dart';
import 'features/shell/incoming_links.dart';
import 'features/security/app_lock.dart';
import 'features/shell/language.dart';
import 'shared/theme.dart';
import 'shared/scroll_performance.dart';
import 'core/brand.dart';

import 'l10n/l10n.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledLicenses();
  SystemChrome.setSystemUIOverlayStyle(
    systemUiOverlayStyle(WidgetsBinding.instance.platformDispatcher.platformBrightness),
  );
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  // The stored language is applied before the first frame (the launch screen
  // stays up meanwhile), so no text shows up in one language and then flips.
  final language = LanguageController(SecureLanguageStore());
  await language.load().timeout(const Duration(seconds: 2), onTimeout: () {});
  runApp(ProviderScope(
    overrides: [languageProvider.overrideWithValue(language)],
    child: const bool.fromEnvironment('PERF_DIAGNOSTICS')
        ? ScrollPerformance(child: GitLabMobileApp())
        : GitLabMobileApp(),
  ));
}

// initialize resets accountsLoaded synchronously. Recovery can then listen for
// the secure account list without waiting for network identity revalidation.
Future<void> initializeSessionWithAiRecovery(SessionController session) {
  final initialization = session.initialize();
  unawaited(AiHistoryCoordinator.instance.startRecovery(session));
  // Not behind the AI gate (plan v6 §8): removing an account must clean a
  // journal a gated build once wrote. Any failure leaves the journal
  // unconfigured or unrecovered, and it then refuses writes.
  unawaited(startAiWriteJournal(session));
  return initialization;
}

Future<bool>? _aiWriteJournalConfiguration;

/// Configures [AiWriteJournal.instance] once per process, then recovers it for
/// the session's stored accounts as soon as they load. Never throws.
Future<void> startAiWriteJournal(SessionController session) async {
  final configured = await (_aiWriteJournalConfiguration ??=
      configureAiWriteJournal());
  if (!configured) return;
  await recoverAiWriteJournalAfterAccountsLoaded(
    session,
    AiWriteJournal.instance,
  );
}

/// Configures [AiWriteJournal.instance] with the secure key store, the
/// Application Support directory and the history-owned account fence. The
/// parameters exist for tests. Returns whether the journal is configured; a
/// failure is swallowed and leaves the journal refusing every write.
Future<bool> configureAiWriteJournal({
  AiJournalKeyStore? keys,
  Future<Directory> Function()? applicationSupport,
  AiJournalAccountFence? fence,
}) async {
  try {
    // Through the cleanup library, so account removal knows the journal can
    // hold writes. An earlier configuration stays in force.
    wireAiWriteJournal(
      keys: keys ?? SecureAiJournalKeyStore(),
      applicationSupport:
          await (applicationSupport ?? getApplicationSupportDirectory)(),
      fence: fence ?? AiHistoryJournalFence(),
    );
    return true;
  } on Object {
    return false;
  }
}

final Expando<Future<void>> _journalRecoveryTails = Expando<Future<void>>(
  'aiWriteJournalRecovery',
);

/// Waits for the session's stored account list the way
/// [AiHistoryCoordinator.startRecovery] does, then passes every stored account
/// to [AiWriteJournal.recoverAfterAccountsLoaded]. When membership changed
/// while recovery ran, it runs again with the current accounts. Calls for one
/// journal run one at a time, so two account lists never sweep orphans
/// concurrently. A failure ends the attempt: unrecovered accounts keep their
/// writes refused.
Future<void> recoverAiWriteJournalAfterAccountsLoaded(
  SessionController session,
  AiWriteJournal journal,
) async {
  if (!session.accountsLoaded) {
    final loaded = Completer<void>();
    void listener() {
      if (session.accountsLoaded && !loaded.isCompleted) loaded.complete();
    }

    session.addListener(listener);
    try {
      await loaded.future;
    } finally {
      session.removeListener(listener);
    }
  }
  Set<String> current() =>
      session.accounts.map((account) => account.key).toSet();
  while (session.accountsLoaded) {
    Set<String>? accounts;
    final previous = _journalRecoveryTails[journal] ?? Future<void>.value();
    final recovery = previous.then((_) {
      if (!session.accountsLoaded) return Future<void>.value();
      // Read when this run starts, not when it was queued.
      final loaded = accounts = current();
      return journal.recoverAfterAccountsLoaded(loaded);
    });
    final tail = recovery.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _journalRecoveryTails[journal] = tail;
    try {
      await recovery;
    } on Object {
      return;
    } finally {
      if (identical(_journalRecoveryTails[journal], tail)) {
        _journalRecoveryTails[journal] = null;
      }
    }
    // A run skipped while the list reloaded repeats once it is loaded again
    // and otherwise stops, as history recovery does.
    if (accounts != null && setEquals(accounts, current())) return;
  }
}

class GitLabMobileApp extends ConsumerStatefulWidget {
  const GitLabMobileApp({super.key});
  @override
  ConsumerState<GitLabMobileApp> createState() => _GitLabMobileAppState();
}
class _GitLabMobileAppState extends ConsumerState<GitLabMobileApp> {
  late final LauncherShortcuts _shortcuts;
  late final IncomingLinks _links;
  late final LanguageController _language;
  late final AiControllers? _ai;
  bool _sessionWasActive = false;
  @override
  void initState() {
    super.initState();
    _language = ref.read(languageProvider)..addListener(_languageChanged);
    _shortcuts = ref.read(launcherShortcutsProvider);
    unawaited(_shortcuts.start());
    // Held here, above the account-keyed tree, so a link that arrives while
    // signed out or during an account switch waits for the next shell.
    _links = ref.read(incomingLinksProvider)..start();
    _ai = aiAssistantEnabled
        ? buildAiControllers(enabled: true, settings: ref.read(aiSettingsProvider))
        : null;
    if (_ai case final ai?) {
      // The controller retains its typed initialization failure for the Me
      // row and settings retry surface; setup must not crash application start.
      unawaited(ai.settings.initialize().catchError((Object _) {}));
    }
    final session = ref.read(sessionProvider);
    unawaited(initializeSessionWithAiRecovery(session));
    // The stored appearance is read alongside the accounts and never gates the
    // first frame: the app renders with ThemeMode.system until it arrives.
    unawaited(ref.read(appearanceProvider).load());
    // Looks for an update once per launch (when allowed); never gates a frame.
    unawaited(ref.read(appUpdateProvider).start());
    // Started before the first frame's app exists, so its back handling runs
    // before the navigator's while the app is locked.
    unawaited(ref.read(appLockProvider).start());
  }
  @override
  void dispose() {
    _language.removeListener(_languageChanged);
    super.dispose();
  }

  // Text comes from l10n during build, so a new language rebuilds everything
  // below; routes, scroll positions and drafts stay as they are.
  void _languageChanged() {
    if (!mounted) return;
    rebuildForLanguage(context);
    // Launcher shortcut labels live outside the widget tree.
    final account = ref.read(sessionProvider).active?.key;
    if (account != null) unawaited(_shortcuts.publish(account));
  }

  void _syncShortcuts(bool signedIn, String? accountKey) {
    _shortcuts.bind(signedIn ? accountKey : null);
    if (!signedIn && _sessionWasActive) {
      unawaited(_shortcuts.clearPublished());
    }
    _sessionWasActive = signedIn;
  }
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final appearance = ref.watch(appearanceProvider);
    return ListenableBuilder(listenable: Listenable.merge([session, appearance, _language]), builder: (context, _) {
      final signedIn = session.active != null && session.api != null;
      _syncShortcuts(signedIn, session.active?.key);
      if (signedIn) {
        return AuthenticatedApp(
          key: ValueKey(session.generation), session: session, appearance: appearance, shortcuts: _shortcuts,
          updates: ref.read(appUpdateProvider), incoming: _links, lock: ref.read(appLockProvider),
          language: _language, ai: _ai,
        );
      }
      return DynamicColorBuilder(builder: (light, dark) {
        final enabled = appearance.useDynamicColor;
        return MaterialApp(
          title: appName, debugShowCheckedModeBanner: false,
          builder: (context, child) => AppLockGate(controller: ref.read(appLockProvider),
            child: applySystemBars(context, child)),
          theme: appTheme(Brightness.light, dynamicScheme: enabled ? flutterScheme(light) : null),
          darkTheme: appTheme(Brightness.dark, dynamicScheme: enabled ? flutterScheme(dark) : null),
          themeMode: appearance.mode,
          locale: _language.locale,
          localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
          supportedLocales: appLocales,
          home: session.resuming
            ? _ResumeScreen(session: session)
            : session.initializing
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : LoginScreen(session: session),
        );
      });
    });
  }
}

class _ResumeScreen extends StatelessWidget {
  const _ResumeScreen({required this.session});
  final SessionController session;
  @override
  Widget build(BuildContext context) {
    final username = session.resumingAccount?.user.username ?? '';
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(child: Center(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.account_tree_outlined, size: 32, color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            child: Text(l10n.restoringAccount(username), style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          const CircularProgressIndicator(),
          TextButton(onPressed: () { unawaited(session.endSession()); }, child: Text(l10n.useAnotherAccount)),
        ]),
      ))),
    );
  }
}
