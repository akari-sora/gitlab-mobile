import 'dart:async';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/shell/app_shortcuts.dart';
import 'features/auth/session_controller.dart';
import 'features/shell/authenticated_app.dart';
import 'shared/theme.dart';
import 'shared/scroll_performance.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledLicenses();
  SystemChrome.setSystemUIOverlayStyle(
    systemUiOverlayStyle(WidgetsBinding.instance.platformDispatcher.platformBrightness),
  );
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  runApp(const ProviderScope(child: bool.fromEnvironment('PERF_DIAGNOSTICS')
      ? ScrollPerformance(child: GitLabMobileApp())
      : GitLabMobileApp()));
}

class GitLabMobileApp extends ConsumerStatefulWidget {
  const GitLabMobileApp({super.key});
  @override
  ConsumerState<GitLabMobileApp> createState() => _GitLabMobileAppState();
}
class _GitLabMobileAppState extends ConsumerState<GitLabMobileApp> {
  late final LauncherShortcuts _shortcuts;
  bool _sessionWasActive = false;
  @override
  void initState() {
    super.initState();
    _shortcuts = ref.read(launcherShortcutsProvider);
    unawaited(_shortcuts.start());
    unawaited(ref.read(sessionProvider).initialize());
    // The stored appearance is read alongside the accounts and never gates the
    // first frame: the app renders with ThemeMode.system until it arrives.
    unawaited(ref.read(appearanceProvider).load());
    // Looks for an update once per launch (when allowed); never gates a frame.
    unawaited(ref.read(appUpdateProvider).start());
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
    return ListenableBuilder(listenable: Listenable.merge([session, appearance]), builder: (context, _) {
      final signedIn = session.active != null && session.api != null;
      _syncShortcuts(signedIn, session.active?.key);
      if (signedIn) {
        return AuthenticatedApp(
          key: ValueKey(session.generation), session: session, appearance: appearance, shortcuts: _shortcuts,
          updates: ref.read(appUpdateProvider),
        );
      }
      return DynamicColorBuilder(builder: (light, dark) {
        final enabled = appearance.useDynamicColor;
        return MaterialApp(
          title: 'GitLab Mobile', debugShowCheckedModeBanner: false,
          builder: applySystemBars,
          theme: appTheme(Brightness.light, dynamicScheme: enabled ? flutterScheme(light) : null),
          darkTheme: appTheme(Brightness.dark, dynamicScheme: enabled ? flutterScheme(dark) : null),
          themeMode: appearance.mode,
          locale: const Locale('zh', 'TW'),
          localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
          supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
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
            child: Text('正在恢復 @$username', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          const CircularProgressIndicator(),
          TextButton(onPressed: () { unawaited(session.endSession()); }, child: const Text('改用其他帳號')),
        ]),
      ))),
    );
  }
}
