import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/shell/authenticated_app.dart';
import 'shared/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: GitLabMobileApp()));
}

class GitLabMobileApp extends ConsumerStatefulWidget {
  const GitLabMobileApp({super.key});
  @override
  ConsumerState<GitLabMobileApp> createState() => _GitLabMobileAppState();
}
class _GitLabMobileAppState extends ConsumerState<GitLabMobileApp> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(sessionProvider).initialize());
    // The stored appearance is read alongside the accounts and never gates the
    // first frame: the app renders with ThemeMode.system until it arrives.
    unawaited(ref.read(appearanceProvider).load());
  }
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final appearance = ref.watch(appearanceProvider);
    return ListenableBuilder(listenable: Listenable.merge([session, appearance]), builder: (context, _) {
      if (session.active != null && session.api != null) {
        return AuthenticatedApp(key: ValueKey(session.generation), session: session, appearance: appearance);
      }
      return MaterialApp(
        title: 'GitLab Mobile', debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light), darkTheme: appTheme(Brightness.dark),
        themeMode: appearance.mode,
        locale: const Locale('zh', 'TW'),
        localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
        supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
        home: session.initializing
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : LoginScreen(session: session),
      );
    });
  }
}
