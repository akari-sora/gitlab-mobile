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
import 'core/read_cache_disk_contract.dart';
import 'core/read_cache_files.dart';
import 'features/auth/login_screen.dart';
import 'features/ai/ai_gate.dart';
import 'features/ai/ai_account_cleanup.dart';
import 'features/ai/ai_history.dart';
import 'features/ai/ai_journal_fence.dart';
import 'features/ai/ai_journal_key_store.dart';
import 'features/ai/ai_run_notification_ui.dart';
import 'features/ai/ai_run_notifications.dart';
import 'features/ai/ai_scope.dart';
import 'features/ai/ai_settings_provider.dart';
import 'features/ai/ai_stores.dart';
import 'features/ai/ai_write_journal.dart';
import 'features/shell/app_shortcuts.dart';
import 'features/auth/session_controller.dart';
import 'features/cache/read_cache_disk_coordinator.dart';
import 'features/cache/read_cache_key_store.dart';
import 'features/cache/read_cache_settings_store.dart';
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
Future<void> initializeSessionWithAiRecovery(
  SessionController session, {
  AiWriteJournal? journal,
  Duration recoveryTimeout = ReadCacheDiskCoordinator.barrierLimit,
}) {
  final initialization = session.initialize();
  final recovery = _sessionRecoveries[session] ??=
      _SessionRecovery(session, recoveryTimeout);
  recovery.start();
  final historyRecovery = AiHistoryCoordinator.instance.startRecovery(
    session,
    runRecovery: recovery.runAi,
  ).catchError((Object _) {});
  unawaited(historyRecovery);
  // Not behind the AI gate (plan v6 §8): removing an account must clean a
  // journal a gated build once wrote. Any failure leaves the journal
  // unconfigured or unrecovered, and it then refuses writes.
  final Future<void> journalRecovery;
  if (journal == null) {
    journalRecovery = startAiWriteJournal(session, runRecovery: recovery.runAi);
  } else {
    journalRecovery = recoverAiWriteJournalAfterAccountsLoaded(
      session,
      journal,
      runRecovery: recovery.runAi,
    );
  }
  unawaited(journalRecovery);
  recovery.startupTask = Future.wait<void>([
    initialization, historyRecovery, journalRecovery,
  ]).then((_) {});
  return initialization;
}

/// Installs the C2 stores without opening the user-controls gate. The file
/// root is resolved by each I/O operation, so a failed provider stays closed.
void configureReadCacheDisk(
  ReadCacheDiskCoordinator coordinator, {
  ReadCacheKeyStore? keys,
  ReadCacheFileStore? files,
  ReadCacheSettingsStore? settings,
}) {
  if (coordinator.configured) return;
  final storage = FlutterReadCacheSecureStorage();
  coordinator.configure(
    keys: keys ?? ReadCacheKeyStore(storage),
    files: files ?? ReadCacheFileStore(root: getApplicationSupportDirectory),
    settings: settings ?? ReadCacheSettingsStore(storage),
  );
}

/// The tail represents the actual operation, including native-I/O completion,
/// not the bounded time for which a caller waits for it.
final class _RecoveryGate {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  Future<T> run<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    // An idle gate has no predecessor. Start its next turn in the caller's
    // zone instead of retaining a completed future from a retired widget clock.
    final previous = _pending++ == 0 ? Future<void>.value() : _tail;
    _tail = previous.then((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _pending--;
      }
    });
    return result.future;
  }
}

final _recoveryGate = _RecoveryGate();
final _sessionRecoveries = Expando<_SessionRecovery>();

@visibleForTesting
Future<void> startupRecoveryQuiescedForTesting(SessionController session) async {
  await _sessionRecoveries[session]?.startupTask;
  await _recoveryGate._tail;
}

/// Installs observers immediately but reserves no gate while session identity
/// is still being read. Every queued scan uses a current immutable decision.
final class _SessionRecovery {
  _SessionRecovery(this.session, this.timeout);

  final SessionController session;
  final Duration timeout;
  Future<void> startupTask = Future<void>.value();
  Completer<void> _decisionChanged = Completer<void>();
  ReadCacheStartupDecision? _seen;
  ReadCacheStartupDecision? _acknowledged;
  Timer? _retry;
  final Map<Object, Timer> _scanTimeouts = {};
  int _attempt = 0;
  bool _disposed = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    configureReadCacheDisk(session.readCache);
    session.addListener(_changed);
    unawaited(session.whenDisposed.then((_) => dispose()));
    _changed();
  }

  void _changed() {
    if (_disposed || session.isDisposed) return;
    final decision = session.readCacheStartupDecision;
    if (identical(decision, _seen)) return;
    _seen = decision;
    _acknowledged = null;
    _attempt = 0;
    _retry?.cancel();
    for (final timer in _scanTimeouts.values) {
      timer.cancel();
    }
    _scanTimeouts.clear();
    _signalDecisionChanged();
    if (decision != null) _queueScan(decision);
  }

  void _queueScan(ReadCacheStartupDecision decision) {
    if (_disposed || !session.isReadCacheDecisionCurrent(decision)) return;
    final round = session.readCache.beginStartupScan(session);
    if (round == null) return;
    var expired = false;
    void expire() {
      _scanTimeouts.remove(round);
      if (_disposed ||
          !session.isReadCacheDecisionCurrent(decision) ||
          !session.readCache.revokeStartup(session, scan: round)) {
        return;
      }
      expired = true;
      _report(ReadCacheCleanupCode.barrierTimedOut, decision);
    }

    final timeout = Timer(this.timeout, expire);
    _scanTimeouts[round] = timeout;
    final scan = _recoveryGate.run(() async {
      if (expired || _disposed ||
          !session.isReadCacheDecisionCurrent(decision)) {
        return false;
      }
      final accounts = session.accounts.map((account) => account.key).toSet();
      return session.readCache.recover(
        decision,
        accountKeys: accounts,
        sessionOwner: session,
        startupScan: round,
      );
    });
    unawaited(
      scan.then(
        (success) {
          timeout.cancel();
          _scanTimeouts.remove(round);
          if (_disposed || !session.isReadCacheDecisionCurrent(decision)) {
            return;
          }
          if (!success && decision.readable && !expired) {
            _report(ReadCacheCleanupCode.cleanupFailed, decision);
          }
          if ((!success || expired) && decision.readable) {
            _scheduleRetry(decision);
          }
          _acknowledge(decision);
        },
        onError: (Object _, StackTrace _) {
          timeout.cancel();
          _scanTimeouts.remove(round);
          if (_disposed || !session.isReadCacheDecisionCurrent(decision)) {
            return;
          }
          if (!expired) _report(ReadCacheCleanupCode.cleanupFailed, decision);
          if (decision.readable) _scheduleRetry(decision);
          _acknowledge(decision);
        },
      ),
    );
  }

  void _report(ReadCacheCleanupCode code, ReadCacheStartupDecision decision) {
    if (_disposed || !session.isReadCacheDecisionCurrent(decision)) return;
    session.readCache.reportCleanup(
      DiskBinding(
        accountKey: decision.resumeAccountKey ?? session.active?.key ?? '',
        generation: session.generation,
      ),
      ReadCacheCleanupState(
        operation: ReadCacheCleanupOperation.startup,
        disposition: ReadCacheCleanupDisposition.diskClosed,
        code: code,
        clearResult: const DiskClearResult(
          keyGoneConfirmed: false,
          directoryGoneConfirmed: false,
          markerDurable: false,
          complete: false,
        ),
      ),
    );
  }

  void _scheduleRetry(ReadCacheStartupDecision decision) {
    const delays = [1, 5, 30];
    final delay = delays[_attempt < delays.length ? _attempt : delays.length - 1];
    _attempt++;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: delay), () {
      if (!_disposed && session.isReadCacheDecisionCurrent(decision)) {
        _queueScan(decision);
      }
    });
  }

  void _signalDecisionChanged() {
    final previous = _decisionChanged;
    _decisionChanged = Completer<void>();
    if (!previous.isCompleted) previous.complete();
  }

  void _acknowledge(ReadCacheStartupDecision decision) {
    if (_disposed || !session.isReadCacheDecisionCurrent(decision)) return;
    _acknowledged = decision;
    _signalDecisionChanged();
  }

  Future<void> runAi(Future<void> Function() action) async {
    while (!_disposed && !session.isDisposed) {
      final changed = _decisionChanged.future;
      final decision = session.readCacheStartupDecision;
      if (decision == null || !identical(decision, _acknowledged) ||
          !session.isReadCacheDecisionCurrent(decision)) {
        await changed;
        continue;
      }
      final ran = await _recoveryGate.run(() async {
        if (_disposed || session.isDisposed ||
            !identical(decision, _acknowledged) ||
            !session.isReadCacheDecisionCurrent(decision)) {
          return false;
        }
        await action();
        return true;
      });
      if (ran) return;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    for (final scan in _scanTimeouts.entries) {
      scan.value.cancel();
      session.readCache.revokeStartup(session, scan: scan.key);
    }
    _scanTimeouts.clear();
    if (identical(_sessionRecoveries[session], this)) {
      _sessionRecoveries[session] = null;
    }
    session.removeListener(_changed);
    _signalDecisionChanged();
  }
}

Future<bool>? _aiWriteJournalConfiguration;

/// Configures [AiWriteJournal.instance] once per process, then recovers it for
/// the session's stored accounts as soon as they load. Never throws.
Future<void> startAiWriteJournal(
  SessionController session, {
  Future<void> Function(Future<void> Function())? runRecovery,
}) async {
  final configured = await (_aiWriteJournalConfiguration ??=
      configureAiWriteJournal());
  if (!configured) return;
  await recoverAiWriteJournalAfterAccountsLoaded(
    session,
    AiWriteJournal.instance,
    runRecovery: runRecovery,
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
  AiWriteJournal journal, {
  Future<void> Function(Future<void> Function())? runRecovery,
}) async {
  if (!session.accountsLoaded) {
    final loaded = Completer<void>();
    void listener() {
      if (session.accountsLoaded && !loaded.isCompleted) loaded.complete();
    }

    session.addListener(listener);
    try {
      await Future.any([loaded.future, session.whenDisposed]);
    } finally {
      session.removeListener(listener);
    }
  }
  Set<String> current() =>
      session.accounts.map((account) => account.key).toSet();
  while (!session.isDisposed && session.accountsLoaded) {
    Set<String>? accounts;
    final previous = _journalRecoveryTails[journal] ?? Future<void>.value();
    final recovery = previous.then((_) async {
      Future<void> recover() async {
        if (session.isDisposed || !session.accountsLoaded) return;
        // Read when the destructive operation starts, not when it was queued.
        final loaded = accounts = current();
        await journal.recoverAfterAccountsLoaded(loaded);
      }
      if (runRecovery == null) {
        await recover();
      } else {
        await runRecovery(recover);
      }
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
    if (session.isDisposed ||
        (accounts != null && setEquals(accounts, current()))) {
      return;
    }
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
  late final AiRunNotifications? _runNotifications;
  late final AiRunNotificationGate? _runNotificationGate;
  late final AppLifecycleListener _readCacheLifecycle;
  _SessionRecovery? _sessionRecovery;
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
    // One per process, above the account-keyed tree like the links: a tap
    // that starts the app is read here and waits for the lock and the shell.
    // Android only; initializing never asks for the permission.
    final notifications = _runNotifications = _ai == null
        ? null
        : AiRunNotifications(text: aiRunNotificationText);
    _runNotificationGate = notifications == null
        ? null
        : AiRunNotificationGate(notifications, lock: ref.read(appLockProvider));
    if (notifications != null && notifications.supported) {
      unawaited(notifications.initialize());
    }
    final session = ref.read(sessionProvider);
    _readCacheLifecycle = AppLifecycleListener(onStateChange: (state) {
      if (state == AppLifecycleState.resumed) {
        final active = session.active;
        // A negative generation only restores the foreground flag; the
        // coordinator rejects it as an activation when no session exists.
        final binding = DiskBinding(
          accountKey: active?.key ?? '',
          generation: active == null ? -1 : session.generation,
        );
        unawaited(session.readCache.resume(binding));
      } else {
        session.readCache.background();
      }
    });
    unawaited(initializeSessionWithAiRecovery(session));
    _sessionRecovery = _sessionRecoveries[session];
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
    _readCacheLifecycle.dispose();
    _sessionRecovery?.dispose();
    _runNotificationGate?.dispose();
    _runNotifications?.dispose();
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
          language: _language, ai: _ai, runNotifications: _runNotificationGate,
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
