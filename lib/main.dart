import 'dart:async';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/ai/ai_gate.dart';
import 'features/ai/ai_history.dart';
import 'features/ai/ai_scope.dart';
import 'features/ai/ai_settings_provider.dart';
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
  return initialization;
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
