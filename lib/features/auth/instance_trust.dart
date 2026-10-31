import 'dart:async';
import 'dart:convert';
import 'dart:io' show SecurityContext, TlsException;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/instance.dart';
import '../../core/instance_ca.dart';

/// Raw secure-storage access for `instance_ca.v1.*` entries. Names are full
/// storage keys so an undecodable name can still be removed exactly.
abstract interface class InstanceTrustStore {
  /// Every `instance_ca.v1.*` entry, by storage key.
  Future<Map<String, String>> readAll();
  Future<String?> read(String storageKey);
  Future<void> write(String storageKey, String value);
  Future<void> delete(String storageKey);
}

const instanceCaPrefix = 'instance_ca.v1.';

String instanceCaStorageKey(String instanceKey) =>
    '$instanceCaPrefix${base64Url.encode(utf8.encode(instanceKey))}';

/// The instance key a storage key names, or null when it cannot be decoded.
String? instanceKeyOfStorageKey(String storageKey) {
  if (!storageKey.startsWith(instanceCaPrefix)) return null;
  try {
    return utf8.decode(
      base64Url.decode(storageKey.substring(instanceCaPrefix.length)),
    );
  } on FormatException {
    return null;
  }
}

/// Device-scoped like the account list, with the same Keychain options.
final class SecureInstanceTrustStore implements InstanceTrustStore {
  SecureInstanceTrustStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> readAll() async => {
    for (final entry in (await _storage.readAll()).entries)
      if (entry.key.startsWith(instanceCaPrefix)) entry.key: entry.value,
  };

  @override
  Future<String?> read(String storageKey) => _storage.read(key: storageKey);

  @override
  Future<void> write(String storageKey, String value) =>
      _storage.write(key: storageKey, value: value);

  @override
  Future<void> delete(String storageKey) => _storage.delete(key: storageKey);
}

/// In memory: tests and the demo, which writes nothing.
final class MemoryInstanceTrustStore implements InstanceTrustStore {
  MemoryInstanceTrustStore([Map<String, String>? values])
    : values = values ?? {};
  final Map<String, String> values;

  @override
  Future<Map<String, String>> readAll() async => {
    for (final entry in values.entries)
      if (entry.key.startsWith(instanceCaPrefix)) entry.key: entry.value,
  };

  @override
  Future<String?> read(String storageKey) async => values[storageKey];

  @override
  Future<void> write(String storageKey, String value) async =>
      values[storageKey] = value;

  @override
  Future<void> delete(String storageKey) async => values.remove(storageKey);
}

/// The CA certificates imported for GitLab instances on this device.
///
/// An entry is written only when the user confirms an import, and removed
/// when the user removes it, when the last saved account of its instance is
/// removed, or by the start-up sweep of entries whose instance has no saved
/// account. Lookups are synchronous so the session can build a client at
/// once; [load] must finish before the first client of a start-up.
final class InstanceTrust extends ChangeNotifier {
  InstanceTrust(this.store);

  /// Empty and already loaded: nothing to read.
  InstanceTrust.memory([InstanceTrustStore? store])
    : store = store ?? MemoryInstanceTrustStore(),
      _loaded = true,
      _readable = true;

  final InstanceTrustStore store;
  final _byInstance = <String, InstanceCaCertificate>{};
  final _storageKeys = <String>{};

  /// Instances whose entry this process wrote or removed. The start-up
  /// sweep never touches them: a CA imported during a sign-in legitimately
  /// has no account yet.
  final _touched = <String>{};
  bool _loaded = false;
  bool _readable = false;
  bool _swept = false;
  bool _disposed = false;
  Future<void>? _loading;

  bool get loaded => _loaded;

  /// False when the stored entries could not be read; every instance then
  /// uses the default roots, and no orphan is removed.
  bool get readable => _readable;

  InstanceCaCertificate? certificateFor(GitLabInstance instance) =>
      _byInstance[instance.key];

  Iterable<String> get instanceKeys => _byInstance.keys;

  /// A new context for one client, or null for the default roots. A stored
  /// certificate the platform no longer accepts falls back to the defaults,
  /// which fail closed.
  SecurityContext? securityContextFor(GitLabInstance instance) {
    final certificate = _byInstance[instance.key];
    if (certificate == null) return null;
    try {
      return certificate.securityContext();
    } on TlsException {
      return null;
    }
  }

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final entries = await store.readAll();
      for (final entry in entries.entries) {
        _storageKeys.add(entry.key);
        final instanceKey = instanceKeyOfStorageKey(entry.key);
        if (instanceKey == null || _touched.contains(instanceKey)) continue;
        // A value this build cannot read is ignored, not deleted: the user
        // can import again, which replaces it.
        final certificate = InstanceCaCertificate.decode(entry.value);
        if (certificate != null) _byInstance[instanceKey] = certificate;
      }
      _readable = true;
    } on Object {
      _readable = false;
    } finally {
      _loaded = true;
      _notify();
    }
  }

  /// Removes entries whose instance has no saved account. Runs once, after
  /// a successful load of both the account list and these entries.
  Future<void> sweepOrphans(Set<String> instancesWithAccounts) async {
    if (_swept || !_loaded || !_readable) return;
    _swept = true;
    for (final storageKey in _storageKeys.toList()) {
      final instanceKey = instanceKeyOfStorageKey(storageKey);
      if (instanceKey != null &&
          (instancesWithAccounts.contains(instanceKey) ||
              _touched.contains(instanceKey))) {
        continue;
      }
      try {
        await store.delete(storageKey);
        _storageKeys.remove(storageKey);
        if (instanceKey != null && !_touched.contains(instanceKey)) {
          _byInstance.remove(instanceKey);
        }
      } on Object {
        // Retried at the next start.
      }
    }
    _notify();
  }

  /// Stores [certificate] for [instance] after the user confirmed it, and
  /// reads it back. Throws [CaCertificateFailure] when the value did not
  /// land; the previous entry, if any, then stays in use.
  Future<void> save(
    GitLabInstance instance,
    InstanceCaCertificate certificate,
  ) async {
    final storageKey = instanceCaStorageKey(instance.key);
    final value = certificate.encode();
    try {
      await store.write(storageKey, value);
      if (await store.read(storageKey) != value) {
        throw const CaCertificateFailure(CaCertificateProblem.saveFailed);
      }
    } on CaCertificateFailure {
      rethrow;
    } on Object {
      throw const CaCertificateFailure(CaCertificateProblem.saveFailed);
    }
    _touched.add(instance.key);
    _storageKeys.add(storageKey);
    _byInstance[instance.key] = certificate;
    _notify();
  }

  /// Deletes the entry and confirms it is gone. Clients already built keep
  /// the context they were given; the next client uses the default roots.
  Future<void> remove(GitLabInstance instance) async {
    final storageKey = instanceCaStorageKey(instance.key);
    try {
      await store.delete(storageKey);
      if (await store.read(storageKey) != null) {
        throw const CaCertificateFailure(CaCertificateProblem.removeFailed);
      }
    } on CaCertificateFailure {
      rethrow;
    } on Object {
      throw const CaCertificateFailure(CaCertificateProblem.removeFailed);
    }
    _touched.add(instance.key);
    _storageKeys.remove(storageKey);
    _byInstance.remove(instance.key);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
