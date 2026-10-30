import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../security/app_lock.dart';
import '../shell/authenticated_app.dart';
import '../shell/build_info.dart';
import '../shell/language.dart';
import 'demo_runtime.dart';
import 'demo_scope.dart';

/// The signed-in shell over [runtime], the way an account would see it, with
/// a "Demo" banner on every page. It has no update check, incoming links or
/// AI notifications, and nothing in it reaches the device's account list or
/// settings. [onExit] returns to the sign-in screen; the caller then disposes
/// [runtime].
class DemoApp extends StatefulWidget {
  const DemoApp({
    super.key,
    required this.runtime,
    required this.onExit,
    this.language,
    this.lock,
    this.buildInfoLoader = loadBuildInfo,
  });

  final DemoRuntime runtime;
  final Future<void> Function() onExit;

  /// The app's language, read only: the demo offers no language picker.
  final LanguageController? language;

  /// The device's app lock. It covers the demo like any other screen (and
  /// holds back presses while locked); the demo offers no switch for it.
  final AppLockController? lock;
  final BuildInfoLoader buildInfoLoader;

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    widget.runtime.session.addListener(_sessionChanged);
  }

  @override
  void dispose() {
    widget.runtime.session.removeListener(_sessionChanged);
    super.dispose();
  }

  /// Should anything end the demo's session, the demo ends with it.
  void _sessionChanged() {
    final session = widget.runtime.session;
    if (session.active == null || session.api == null) {
      unawaited(_exit());
    }
  }

  Future<void> _exit() async {
    if (_leaving) return;
    _leaving = true;
    if (mounted) setState(() {});
    await widget.onExit();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final session = runtime.session;
    if (_leaving || session.active == null || session.api == null) {
      return const ColoredBox(color: Colors.transparent);
    }
    return UncontrolledProviderScope(
      container: runtime.container,
      child: DemoScope(
        exit: _exit,
        child: AuthenticatedApp(
          session: session,
          appearance: runtime.appearance,
          shortcuts: runtime.shortcuts,
          language: widget.language,
          lock: widget.lock,
          buildInfoLoader: widget.buildInfoLoader,
          ai: runtime.ai,
          aiSessionFactory: runtime.aiSessionFactory,
          offlineCoordinator: runtime.offline,
          writeJournal: runtime.journal,
        ),
      ),
    );
  }
}
