import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

void main() {
  test('absence defaults to enabled without writing', () async {
    final storage = _MemoryStorage();
    final settings = ReadCacheSettingsStore(storage);

    expect(await settings.read(), ReadCacheSettingsState.enabled);
    expect(storage.values, isEmpty);
    expect(storage.writes, 0);
  });

  test('only canonical values are readable', () async {
    final storage = _MemoryStorage();
    final settings = ReadCacheSettingsStore(storage);

    storage.values[ReadCacheSettingsStore.key] = '1';
    expect(await settings.read(), ReadCacheSettingsState.enabled);
    storage.values[ReadCacheSettingsStore.key] = '0';
    expect(await settings.read(), ReadCacheSettingsState.disabled);
    for (final invalid in <String>['', 'true', 'false', '2', ' 0', '0\n']) {
      storage.values[ReadCacheSettingsStore.key] = invalid;
      expect(await settings.read(), ReadCacheSettingsState.unavailable);
      expect(storage.values[ReadCacheSettingsStore.key], invalid);
    }
    expect(storage.writes, 0);
  });

  test('unavailable read is not mistaken for absence or disabled', () async {
    final storage = _MemoryStorage()..failRead = true;
    expect(
      await ReadCacheSettingsStore(storage).read(),
      ReadCacheSettingsState.unavailable,
    );
    expect(storage.writes, 0);
  });

  test('writes canonical values and requires exact readback', () async {
    final storage = _MemoryStorage();
    final settings = ReadCacheSettingsStore(storage);

    expect(await settings.writeEnabled(false), isTrue);
    expect(storage.values, <String, String>{ReadCacheSettingsStore.key: '0'});
    expect(await settings.read(), ReadCacheSettingsState.disabled);
    expect(await settings.writeEnabled(true), isTrue);
    expect(storage.values, <String, String>{ReadCacheSettingsStore.key: '1'});
    expect(await settings.read(), ReadCacheSettingsState.enabled);
  });

  test('write, readback and mismatch failures are never successful', () async {
    for (final enabled in <bool>[false, true]) {
      final failedWrite = _MemoryStorage()..failWrite = true;
      expect(
        await ReadCacheSettingsStore(failedWrite).writeEnabled(enabled),
        isFalse,
      );
      expect(failedWrite.values, isEmpty);

      final failedReadback = _MemoryStorage()..failRead = true;
      expect(
        await ReadCacheSettingsStore(failedReadback).writeEnabled(enabled),
        isFalse,
      );
      // A failed readback does not prove the preceding write failed.
      expect(
        failedReadback.values[ReadCacheSettingsStore.key],
        enabled ? '1' : '0',
      );

      final mismatch = _MemoryStorage()..replacement = enabled ? '0' : '1';
      expect(
        await ReadCacheSettingsStore(mismatch).writeEnabled(enabled),
        isFalse,
      );
    }
  });
}

final class _MemoryStorage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  bool failRead = false;
  bool failWrite = false;
  String? replacement;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('synthetic native read error');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (failWrite) throw StateError('synthetic native write error');
    values[key] = replacement ?? value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}
