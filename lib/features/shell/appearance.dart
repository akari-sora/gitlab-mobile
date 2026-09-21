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
/// stored value is a plain [ThemeMode] name: no credential, no account and no
/// repository content is persisted here.
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

/// Holds the appearance choice for the whole app. [load] never blocks the
/// first frame: the controller starts on [ThemeMode.system] and notifies its
/// listeners only once a stored value has actually been read.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._store);
  final AppearanceStore _store;
  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;
  bool _disposed = false;
  ThemeMode get mode => _mode;
  bool get loaded => _loaded;

  Future<void> load() async {
    String? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      // An unreadable key store must not block or fail the app start; the
      // user simply keeps the system appearance until they choose again.
      stored = null;
    }
    _loaded = true;
    _apply(themeModeFrom(stored));
  }

  Future<void> select(ThemeMode mode) async {
    _apply(mode);
    try {
      await _store.write(mode.name);
    } catch (_) {
      // A rejected write only costs persistence: the choice stays in memory
      // for this run instead of crashing or reverting under the user.
    }
  }

  void _apply(ThemeMode mode) {
    if (_disposed || _mode == mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
