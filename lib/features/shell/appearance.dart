import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The appearance choice is a device preference rather than account data, so
/// it is shared by every account on this device and survives account switches.
abstract interface class AppearanceStore {
  Future<String?> read();
  Future<void> write(String? value);
}

/// Written through `flutter_secure_storage` like the account list and the
/// editor drafts, so "the app only writes to secure storage" stays true. The
/// stored value is a theme mode plus the dynamic-colour flag: no credential,
/// no account and no repository content is persisted here.
final class SecureAppearanceStore implements AppearanceStore {
  SecureAppearanceStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  static const key = 'gitlab_mobile_appearance_v1';
  @override
  Future<String?> read() => _storage.read(key: key);
  @override
  Future<void> write(String? value) => value == null
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);
}

/// Unknown, empty and missing values are the system default. A stored value
/// is never trusted to name a [ThemeMode] that this build still knows.
ThemeMode themeModeFrom(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

/// Android 12+ can build a scheme from the wallpaper. Other platforms, and a
/// record that predates the flag, keep this default.
bool dynamicColorDefault() => defaultTargetPlatform == TargetPlatform.android;

/// Legacy records are a bare [ThemeMode] name. Newer records are `mode|1` or
/// `mode|0`. Anything else falls back through [themeModeFrom].
String encodeAppearance(ThemeMode mode, bool useDynamicColor) =>
    '${mode.name}|${useDynamicColor ? '1' : '0'}';

(ThemeMode, bool?) decodeAppearance(String? value) {
  if (value == null) {
    return (ThemeMode.system, null);
  }
  final parts = value.split('|');
  if (parts.length == 2 && (parts[1] == '0' || parts[1] == '1')) {
    return (themeModeFrom(parts[0]), parts[1] == '1');
  }
  return (themeModeFrom(value), null);
}

/// Holds the appearance choice for the whole app. [load] never blocks the
/// first frame: the controller starts on [ThemeMode.system] and notifies once
/// the read finishes, including when the stored choice matches the default, so
/// listeners can observe [loaded].
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._store);
  final AppearanceStore _store;
  ThemeMode _mode = ThemeMode.system;
  bool _useDynamicColor = dynamicColorDefault();
  bool _loaded = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _writes;
  ThemeMode get mode => _mode;
  bool get useDynamicColor => _useDynamicColor;
  bool get loaded => _loaded;

  Future<void> load() async {
    final generation = _generation;
    String? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      // An unreadable key store must not block or fail the app start; the
      // user simply keeps the system appearance until they choose again.
      stored = null;
    }
    if (_disposed) return;
    final becameLoaded = !_loaded;
    _loaded = true;
    if (generation != _generation) {
      if (becameLoaded) notifyListeners();
      return;
    }
    final (mode, dynamicColor) = decodeAppearance(stored);
    final useDynamic = dynamicColor ?? dynamicColorDefault();
    if (becameLoaded && _mode == mode && _useDynamicColor == useDynamic) {
      notifyListeners();
      return;
    }
    _apply(mode, useDynamic);
  }

  Future<void> select(ThemeMode mode) {
    final generation = ++_generation;
    final useDynamicColor = _useDynamicColor;
    _apply(mode, useDynamicColor);
    return _enqueueWrite(generation, mode, useDynamicColor);
  }

  Future<void> setUseDynamicColor(bool value) {
    final generation = ++_generation;
    final mode = _mode;
    _apply(mode, value);
    return _enqueueWrite(generation, mode, value);
  }

  /// Devices without a dynamic scheme must not keep the Android default of on.
  /// Ignored until [load] has finished so a stored theme mode is not dropped.
  Future<void> clearUnsupportedDynamicColor() {
    if (_disposed || !_loaded || !_useDynamicColor) return Future<void>.value();
    final generation = ++_generation;
    final mode = _mode;
    _apply(mode, false);
    return _enqueueWrite(generation, mode, false);
  }

  Future<void> _enqueueWrite(int generation, ThemeMode mode, bool useDynamicColor) {
    final encoded = encodeAppearance(mode, useDynamicColor);
    // The chain starts here, in the caller's zone, so a write scheduled from a
    // widget test is flushed by that test. A later call in the same turn is
    // chained and the stale generation is skipped before it touches the store.
    final previous = _writes;
    final Future<void> next = previous == null
        ? Future<void>.microtask(() => _commit(generation, encoded))
        : previous.then((_) => _commit(generation, encoded));
    _writes = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _commit(int generation, String encoded) async {
    if (_disposed || generation != _generation) return;
    try {
      await _store.write(encoded);
    } catch (_) {
      // A rejected write only costs persistence: the choice stays in memory
      // for this run instead of crashing or reverting under the user.
    }
  }

  void _apply(ThemeMode mode, bool useDynamicColor) {
    if (_disposed || (_mode == mode && _useDynamicColor == useDynamicColor)) {
      return;
    }
    _mode = mode;
    _useDynamicColor = useDynamicColor;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
