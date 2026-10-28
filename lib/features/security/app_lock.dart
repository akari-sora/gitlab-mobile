import 'dart:async';

import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/brand.dart';

import '../../l10n/l10n.dart';

/// The device check behind the app lock: biometrics, or the screen lock's
/// PIN, pattern or password where there are no biometrics.
abstract interface class AppLockAuthenticator {
  /// Whether the device has a screen lock the app can ask for.
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

final class LocalAuthAuthenticator implements AppLockAuthenticator {
  LocalAuthAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      // Cancelled, locked out, no screen lock, or a platform without the
      // plugin: the app stays locked and the user can try again.
      return false;
    }
  }
}

abstract interface class AppLockStore {
  Future<bool> read();
  Future<void> write(bool enabled);
}

/// One device-wide flag, shared by every account like the appearance.
final class SecureAppLockStore implements AppLockStore {
  SecureAppLockStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const key = 'gitlab_mobile_app_lock_v1';

  @override
  Future<bool> read() async => await _storage.read(key: key) == '1';

  @override
  Future<void> write(bool enabled) => enabled
      ? _storage.write(key: key, value: '1')
      : _storage.delete(key: key);
}

/// The opt-in app lock. When on, nothing of the app shows until the device
/// check passes: at start, and after the app has been away for [relockAfter].
/// While locked, system back is held so nothing changes behind the lock.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({
    required AppLockStore store,
    required AppLockAuthenticator authenticator,
    this.relockAfter = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _store = store,
       _authenticator = authenticator,
       _clock = clock ?? DateTime.now;

  final AppLockStore _store;
  final AppLockAuthenticator _authenticator;
  final Duration relockAfter;
  final DateTime Function() _clock;

  bool _loaded = false;
  bool _loadFailed = false;
  int _loadTicket = 0;
  bool _enabled = false;
  bool _available = false;
  bool _locked = false;
  bool _authenticating = false;
  bool _started = false;
  bool _disposed = false;
  int _refusedUnlocks = 0;
  DateTime? _awaySince;

  /// False until the stored choice is known; the app stays covered until then.
  bool get loaded => _loaded;
  bool get loadFailed => _loadFailed;
  bool get enabled => _enabled;
  bool get offlineCovering => !_loaded || _loadFailed || locked;

  /// Whether the device has a screen lock, so the lock can be turned on.
  bool get available => _available;
  bool get locked => _enabled && _locked;
  bool get authenticating => _authenticating;

  /// Whether the app content must be covered right now.
  bool get covering => !_loaded || locked;

  /// Unlock attempts that ended with the app still locked: cancelled or not
  /// passed. A notification tap waiting behind the lock is dropped when this
  /// changes, so a refused unlock never navigates.
  int get refusedUnlocks => _refusedUnlocks;

  /// The lock is on and the app is away: coming back may lock it again, so
  /// nothing opens for a notification tap until the app is back.
  bool get away => _enabled && _awaySince != null;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await _loadSettings();
    if (_disposed) return;
    // Only the settings switch needs this; it never holds the cover up.
    final available = await _authenticator.available();
    if (_disposed) return;
    _available = available;
    notifyListeners();
  }

  /// The offline shell keeps its cover visible until this read succeeds.
  Future<void> reload() async {
    if (!_started) return start();
    if (_disposed) return;
    _loaded = false;
    notifyListeners();
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    final ticket = ++_loadTicket;
    var enabled = false;
    var failed = false;
    try {
      enabled = await _store.read();
    } catch (_) {
      enabled = false;
      failed = true;
    }
    if (_disposed || ticket != _loadTicket) return;
    _loadFailed = failed;
    _enabled = enabled;
    _locked = enabled;
    _loaded = true;
    notifyListeners();
  }

  /// Asks for the device check and opens the app when it passes.
  Future<bool> unlock() async {
    if (!locked || _authenticating) return !locked;
    final passed = await _check(l10n.unlockNamedApp(appName));
    if (_disposed) return passed;
    // The check reports its end before this point, still locked either way;
    // only here is a pass told apart from a refusal.
    if (passed) {
      _locked = false;
    } else {
      _refusedUnlocks++;
    }
    notifyListeners();
    return passed;
  }

  /// Turning the lock on needs a passing check first, so nobody locks
  /// themselves out with a screen lock they cannot answer.
  Future<bool> setEnabled(bool value) async {
    if (value == _enabled || _authenticating) return value == _enabled;
    if (value && !await _check(l10n.enableAppLockAfterConfirm)) return false;
    try {
      await _store.write(value);
    } catch (_) {
      return false;
    }
    if (_disposed) return false;
    _enabled = value;
    _locked = false;
    _awaySince = null;
    notifyListeners();
    return true;
  }

  Future<bool> _check(String reason) async {
    _authenticating = true;
    notifyListeners();
    try {
      return await _authenticator.authenticate(reason);
    } finally {
      _authenticating = false;
      // The check itself sends the app to the background (the system's
      // credential screen); that time away does not count.
      _awaySince = null;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled || _authenticating) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _awaySince ??= _clock();
      case AppLifecycleState.resumed:
        final since = _awaySince;
        _awaySince = null;
        if (since != null &&
            !_locked &&
            _clock().difference(since) >= relockAfter) {
          _locked = true;
          notifyListeners();
        } else if (since != null) {
          // Back without locking again; a tap waiting for that may open.
          notifyListeners();
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  Future<bool> didPopRoute() async => locked;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => locked;

  @override
  void dispose() {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// Covers the app while [controller] is locked, and asks for the device check
/// as soon as the lock shows. Before the stored choice is known it is a plain
/// cover, so content never flashes up before a lock.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});
  final AppLockController? controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
    _maybePrompt();
  }

  @override
  void didUpdateWidget(covariant AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_changed);
      widget.controller?.addListener(_changed);
      _maybePrompt();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _maybePrompt();
  }

  /// One automatic prompt each time the lock comes up; after a cancel the
  /// user asks again with the button.
  void _maybePrompt() {
    final lock = widget.controller;
    if (lock == null || !lock.locked) {
      _prompted = false;
      return;
    }
    if (_prompted || lock.authenticating) return;
    _prompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && lock.locked) unawaited(lock.unlock());
    });
  }

  @override
  Widget build(BuildContext context) {
    final lock = widget.controller;
    if (lock == null) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Hidden from touch, focus and screen readers while covered.
        ExcludeSemantics(
          excluding: lock.covering,
          child: IgnorePointer(ignoring: lock.covering, child: widget.child),
        ),
        if (lock.covering) _LockCover(controller: lock),
      ],
    );
  }
}

class _LockCover extends StatelessWidget {
  const _LockCover({required this.controller});
  final AppLockController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: !controller.locked
          ? const SizedBox.expand()
          : SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.lock_outline,
                          size: 32,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          l10n.namedAppIsLocked(appName),
                          style: theme.textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.unlockWithBiometricOrLock,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        key: const ValueKey('app-lock-unlock'),
                        onPressed: controller.authenticating
                            ? null
                            : () => unawaited(controller.unlock()),
                        icon: const Icon(Icons.fingerprint),
                        label: Text(l10n.unlockAction),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
