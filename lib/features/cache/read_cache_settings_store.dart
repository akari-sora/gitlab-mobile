import 'read_cache_key_store.dart';

/// An unreadable or invalid value is distinct from a confirmed disabled value.
enum ReadCacheSettingsState { enabled, disabled, unavailable }

/// Device-wide preference. This primitive does not start cleanup or open the
/// cache; the coordinator owns those transitions and their ordering.
final class ReadCacheSettingsStore {
  ReadCacheSettingsStore([ReadCacheSecureStorage? storage])
    : _storage = storage ?? FlutterReadCacheSecureStorage();

  static const key = 'gitlab_mobile_read_cache_v1';

  final ReadCacheSecureStorage _storage;

  Future<ReadCacheSettingsState> read() async {
    try {
      final value = await _storage.read(key);
      return switch (value) {
        null || '1' => ReadCacheSettingsState.enabled,
        '0' => ReadCacheSettingsState.disabled,
        _ => ReadCacheSettingsState.unavailable,
      };
    } on Object {
      // Native errors can contain private values; do not retain or expose them.
      return ReadCacheSettingsState.unavailable;
    }
  }

  /// Returns success only after the exact value is read back. A failed write
  /// may still have reached storage, so callers must keep the cache fenced.
  Future<bool> writeEnabled(bool enabled) async {
    final value = enabled ? '1' : '0';
    try {
      await _storage.write(key, value);
      return await _storage.read(key) == value;
    } on Object {
      return false;
    }
  }
}
