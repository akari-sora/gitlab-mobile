import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'read_cache_cipher.dart';
import 'read_cache_disk_contract.dart';

const readCacheAccountByteLimit = 32 * 1024 * 1024;
const readCacheDeviceByteLimit = 96 * 1024 * 1024;
const readCacheRetention = Duration(days: 7);
const readCacheTemporaryRetention = Duration(hours: 1);

enum ReadCacheFileFailure {
  keyUnavailable,
  invalidKey,
  invalidName,
  untrustedPath,
  tooLarge,
  capacity,
  io,
}

/// No paths, account identifiers, file contents or underlying OS errors escape.
final class ReadCacheFileException implements Exception {
  const ReadCacheFileException(this.code);
  final ReadCacheFileFailure code;

  @override
  String toString() => 'ReadCacheFileException(${code.name})';
}

/// Read, staging and before-rename faults execute in the background isolate.
/// The renamed checkpoints execute synchronously on the committing isolate.
/// Production leaves this unset; a throwing hook models process interruption.
enum ReadCacheFileCheckpoint {
  beforeRead,
  temporaryCreated,
  temporaryWritten,
  temporaryFlushed,
  beforeEntryRename,
  entryRenamed,
  beforeIndexRename,
  indexRenamed,
  evictionFileDeleted,
}

final class ReadCacheFileUsage {
  const ReadCacheFileUsage({
    required this.accountBytes,
    required this.deviceBytes,
  });
  final int accountBytes, deviceBytes;
}

enum ReadCacheDirectoryState { absent, emptyDirectory, hasFiles }

enum ReadCacheCommitResult { committed, notPermitted, alreadyConsumed }

/// Opaque, single-use ciphertext temporary. Only its staging isolate's caller
/// may commit or discard it; paths, account identity and keys are not exposed.
@pragma('vm:isolate-unsendable')
final class ReadCacheStagedWrite {
  ReadCacheStagedWrite._(this._staged, this._mayCommit, this._checkpoint)
    : _owner = Isolate.current.controlPort;

  final _StagedFile _staged;
  final bool Function() _mayCommit;
  final void Function(ReadCacheFileCheckpoint)? _checkpoint;
  final SendPort _owner;
  bool _consumed = false;

  String get fileName => _staged.fileName;
  int get plaintextBytes => _staged.plaintextBytes;
  int get ciphertextBytes => _staged.ciphertextBytes;

  void _requireOwner() {
    if (Isolate.current.controlPort != _owner) {
      throw const ReadCacheFileException(ReadCacheFileFailure.io);
    }
  }

  /// No await or isolate hop may separate the live permission check and rename.
  /// A refusal or ordinary failure consumes the handle and cleans its temporary.
  /// Throws [ReadCacheFileException] for untrusted paths, file validation or I/O
  /// failures, or a throwing gate. Cleanup can also throw after a refusal;
  /// untrusted ancestors leave the ciphertext temporary for stale-temp recovery.
  ReadCacheCommitResult commit() {
    _requireOwner();
    if (_consumed) return ReadCacheCommitResult.alreadyConsumed;
    _consumed = true;
    return _guardSync(() {
      final files = _staged.files;
      var committed = false;
      try {
        // A revoked caller may already have cleared the account directory.
        if (!_mayCommit()) return ReadCacheCommitResult.notPermitted;
        if (!files.directories()) {
          throw const ReadCacheFileException(
            ReadCacheFileFailure.untrustedPath,
          );
        }
        files.requireFile(_staged.temporaryPath);
        if (File(_staged.temporaryPath).lengthSync() != ciphertextBytes) {
          throw const ReadCacheFileException(ReadCacheFileFailure.io);
        }
        final destination = '${files.account}/$fileName';
        files.requireFile(destination, absentAllowed: true);
        final index = _staged.index;
        if (index != null) files.requireIndexFiles(index, chainVerified: true);
        if (!_mayCommit()) return ReadCacheCommitResult.notPermitted;
        File(_staged.temporaryPath).renameSync(destination);
        committed = true;
        _checkpoint?.call(
          fileName == 'index.v1.bin'
              ? ReadCacheFileCheckpoint.indexRenamed
              : ReadCacheFileCheckpoint.entryRenamed,
        );
        return ReadCacheCommitResult.committed;
      } finally {
        // Rename consumed the temporary. Rechecking ancestors after this point
        // could turn a committed write into a failure or mask a checkpoint error.
        if (!committed) files.deleteTemporary(_staged.temporaryPath);
      }
    });
  }

  /// Idempotent and synchronous. Never follows replaced directories or links.
  /// Throws [ReadCacheFileException] on untrusted paths or I/O failures. An
  /// untrusted ancestor leaves the ciphertext temporary for stale-temp recovery;
  /// the handle remains consumed even when cleanup throws.
  void discard() {
    _requireOwner();
    if (_consumed) return;
    _consumed = true;
    _guardSync(() => _staged.files.deleteTemporary(_staged.temporaryPath));
  }
}

/// Atomic, bounded primitives only. The coordinator owns admission, account
/// serialization, leases, markers, key creation, recovery and LRU decisions.
/// Constructing this store performs no I/O and never selects a platform root.
/// An untrustedPath from any path is device-wide fail-closed: reads, writes
/// (including staging, commit and discard), usage(), scans, eviction, temporary
/// cleanup, accountDirectoryNames(), accountDirectoryState(),
/// clearAccountDirectoriesExcept() and explicit clears. The coordinator fences
/// every account and escalates to clearRoot(); a failed clear keeps the cache
/// closed. Foreign names and wrong directory types can be cleared; special
/// files cannot be removed in the app, so the cache stays closed.
///
/// Capacity checks are best effort across accounts: separate staging isolates
/// can each observe room before the other's temporary is fully written or
/// renamed.
/// C2c must serialize device-wide capacity checks through staging and commit or
/// discard; per-account queues alone do not close this check-then-rename window.
final class ReadCacheFileStore {
  ReadCacheFileStore({
    required Future<Directory> Function() root,
    DateTime Function()? clock,
    this.checkpoint,
  }) : _root = root,
       _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _root;
  final DateTime Function() _clock;
  final void Function(ReadCacheFileCheckpoint)? checkpoint;

  Future<String> _resolveRoot() async {
    try {
      return (await _root()).absolute.path;
    } on Object {
      // Platform directory providers can throw native errors as well as file
      // errors. Neither may expose paths or plugin details to cache callers.
      throw const ReadCacheFileException(ReadCacheFileFailure.io);
    }
  }

  Future<T> _run<T>(
    String accountKey,
    List<int>? key,
    Future<T> Function(_Files files, List<int> key) action,
  ) async {
    final keySnapshot = _snapshotKey(key);
    final path = await _resolveRoot();
    final now = _clock().toUtc();
    final hook = checkpoint;
    return _background(path, accountKey, now, hook, keySnapshot, action);
  }

  /// The gate stays on the caller isolate, before dispatch and after staging.
  /// Null means permission was withdrawn; no staged temporary remains.
  /// Staging may create the account directory chain. This future's completion is
  /// the quiescence acknowledgement: [Isolate.run] cannot be aborted, so the
  /// coordinator must await it before clearing, even after revoking permission.
  Future<ReadCacheStagedWrite?> stageEntry(
    ProjectedDiskEntry entry,
    List<int>? key, {
    required bool Function() mayCommit,
  }) => _stage(entry.accountKey, key, mayCommit, _entryStage(entry));

  /// Stages an index with the gate on the caller isolate, as in [stageEntry].
  /// Staging may create the account directory chain. This future's completion is
  /// the quiescence acknowledgement: [Isolate.run] cannot be aborted, so the
  /// coordinator must await it before clearing, even after revoking permission.
  /// Null means permission was withdrawn; no staged temporary remains.
  Future<ReadCacheStagedWrite?> stageIndex(
    String accountKey,
    List<int>? key,
    ReadCacheIndex index, {
    required bool Function() mayCommit,
  }) => _stage(accountKey, key, mayCommit, _indexStage(index));

  Future<ReadCacheStagedWrite?> _stage(
    String accountKey,
    List<int>? key,
    bool Function() mayCommit,
    Future<_StagedFile> Function(_Files, List<int>) action,
  ) async {
    if (!_guardSync(mayCommit)) return null;
    final keySnapshot = _snapshotKey(key);
    final path = await _resolveRoot();
    final now = _clock().toUtc();
    final hook = checkpoint;
    // Resolving a platform root can yield; check again immediately before spawn.
    if (!_guardSync(mayCommit)) return null;
    final staged = await _background(
      path,
      accountKey,
      now,
      hook,
      keySnapshot,
      action,
    );
    final handle = ReadCacheStagedWrite._(staged, mayCommit, hook);
    var permitted = false;
    try {
      permitted = _guardSync(mayCommit);
      return permitted ? handle : null;
    } finally {
      if (!permitted) handle.discard();
    }
  }

  /// Ungated convenience; coordinators use stageEntry and a live commit gate.
  Future<String> writeEntry(ProjectedDiskEntry entry, List<int>? key) async {
    final staged = (await stageEntry(entry, key, mayCommit: _alwaysPermitted))!;
    staged.commit();
    return staged.fileName;
  }

  /// Returns null when missing or expired. The caller evicts on null so expired
  /// files do not remain on disk indefinitely.
  /// [expectedBodyKind] selects the pre-read and decrypt ceiling: JSON, page and
  /// text use 1 MiB, terminal logs use 2 MiB (plus the 29-byte envelope on disk).
  /// Omitting it retains the terminal-log ceiling for unknown recovery entries.
  /// The authenticated body kind must also match a supplied expectation. With
  /// [expectedBodyKind], an entry of another kind throws bindingMismatch (even
  /// when expired) and one above that kind's ceiling throws tooLarge; the
  /// caller treats both like null and evicts.
  Future<ProjectedDiskEntry?> readEntry(
    String accountKey,
    List<int>? key,
    String canonicalKey, {
    ReadCacheBodyKind? expectedBodyKind,
  }) => _run(accountKey, key, (files, key) async {
    final name = await const ReadCacheCipher().entryFileName(key, canonicalKey);
    return files.readEntry(
      key,
      name,
      expectedCanonicalKey: canonicalKey,
      expectedBodyKind: expectedBodyKind,
    );
  });

  /// Recovery can authenticate an entry discovered by its opaque file name.
  /// This does not scan, delete, rebuild an index or choose an eviction policy.
  /// Returns null when missing or expired; the caller evicts on null.
  /// [expectedBodyKind] has the same ceiling and binding checks, and the same
  /// bindingMismatch and tooLarge failures, as [readEntry].
  Future<ProjectedDiskEntry?> readEntryFile(
    String accountKey,
    List<int>? key,
    String fileName, {
    ReadCacheBodyKind? expectedBodyKind,
  }) => _run(
    accountKey,
    key,
    (files, key) =>
        files.readEntry(key, fileName, expectedBodyKind: expectedBodyKind),
  );

  Future<List<String>> entryFiles(String accountKey, List<int>? key) =>
      _run(accountKey, key, (files, _) async => files.entryFiles());

  Future<void> writeIndex(
    String accountKey,
    List<int>? key,
    ReadCacheIndex index,
  ) async {
    final staged = (await stageIndex(
      accountKey,
      key,
      index,
      mayCommit: _alwaysPermitted,
    ))!;
    staged.commit();
  }

  /// Silently drops entries whose files are missing or have mismatched sizes.
  /// The caller reconciles entryFiles() with this result during recovery.
  Future<ReadCacheIndex?> readIndex(String accountKey, List<int>? key) =>
      _run(accountKey, key, (files, key) async {
        final bytes = files.read('index.v1.bin', readCacheIndexLimit);
        if (bytes == null) return null;
        final plain = await const ReadCacheCipher().decrypt(
          key: key,
          accountKey: accountKey,
          fileName: 'index.v1.bin',
          envelope: bytes,
          plaintextLimit: readCacheIndexLimit,
        );
        final index = const ReadCacheCipher().decodeIndex(plain);
        // File-before-index eviction can leave a stale index after a crash.
        // Return only extant references, without silently writing a repair.
        return ReadCacheIndex(
          entries: index.entries.where(files.indexFileExists).toList(),
        );
      });

  /// Explicit file-before-index eviction. A crash leaves an old index which
  /// readIndex filters. The caller commits its replacement index separately.
  Future<void> evict(String accountKey, List<int>? key, String fileName) =>
      _run(accountKey, key, (files, _) async {
        files.deleteEntry(fileName);
        files.checkpoint?.call(ReadCacheFileCheckpoint.evictionFileDeleted);
      });

  Future<int> removeStaleTemporaryFiles(String accountKey, List<int>? key) =>
      _run(accountKey, key, (files, _) async => files.removeStaleTemporary());

  Future<ReadCacheFileUsage> usage(String accountKey, List<int>? key) =>
      _run(accountKey, key, (files, _) async => files.usage());

  /// Keyless inspection for startup/clear decisions; never creates directories.
  /// Only lowercase 32-hex directory names are accepted. Links, foreign names
  /// and wrong node types fail closed with untrustedPath.
  Future<List<String>> accountDirectoryNames() =>
      _runKeyless('', (files) => files.accountDirectoryNames());

  /// Keyless, non-creating inspection. Temporary files count as files; links or
  /// non-file children fail closed rather than being treated as empty.
  Future<ReadCacheDirectoryState> accountDirectoryState(String accountKey) =>
      _runKeyless(accountKey, (files) => files.accountDirectoryState());

  /// Explicit startup/clear primitive. The caller owns the fence/marker and
  /// retention policy. Validates the full inventory before deleting anything;
  /// nested links are unlinked without traversing their targets.
  /// [retainedAccountKeys] contains original account keys, NOT the hashed names
  /// returned by [accountDirectoryNames]. Passing those names would retain no
  /// matching account directories and could delete every account directory.
  Future<void> clearAccountDirectoriesExcept(Set<String> retainedAccountKeys) {
    final retainedNames = retainedAccountKeys
        .map(ReadCacheCipher.accountDirectoryName)
        .toSet();
    return _runKeyless(
      '',
      (files) => files.clearAccountDirectoriesExcept(retainedNames),
    );
  }

  /// Keyless explicit clears: the caller owns the fence/marker. Links are
  /// unlinked, never followed. These never create a directory or key.
  Future<void> clearAccount(String accountKey) =>
      _runKeyless(accountKey, (files) => files.clear(all: false));
  Future<void> clearRoot() =>
      _runKeyless('', (files) => files.clear(all: true));

  Future<T> _runKeyless<T>(String accountKey, T Function(_Files) action) async {
    final path = await _resolveRoot();
    final now = _clock().toUtc();
    return Isolate.run(
      () => _guard(() async => action(_Files(path, accountKey, now, null))),
    );
  }
}

bool _alwaysPermitted() => true;

List<int> _snapshotKey(List<int>? key) {
  // No root resolution, stat or cleanup without an available valid key.
  if (key == null) {
    throw const ReadCacheFileException(ReadCacheFileFailure.keyUnavailable);
  }
  if (key.length != 32 || key.any((byte) => byte < 0 || byte > 255)) {
    throw const ReadCacheFileException(ReadCacheFileFailure.invalidKey);
  }
  return List<int>.of(key);
}

// Construct isolate actions outside methods that receive the live gate. Dart
// closures may otherwise capture their shared context, including owner state.
Future<_StagedFile> Function(_Files, List<int>) _entryStage(
  ProjectedDiskEntry entry,
) => (files, key) async {
  const cipher = ReadCacheCipher();
  final name = await cipher.entryFileName(key, entry.canonicalKey);
  final plain = cipher.encodeEntry(entry);
  final bytes = await cipher.encrypt(
    key: key,
    accountKey: entry.accountKey,
    fileName: name,
    plaintext: plain,
    plaintextLimit: entry.plaintextLimit,
  );
  return files.stage(name, bytes, plaintextBytes: plain.length);
};

Future<_StagedFile> Function(_Files, List<int>) _indexStage(
  ReadCacheIndex index,
) => (files, key) async {
  const cipher = ReadCacheCipher();
  final plain = cipher.encodeIndex(index);
  files.requireIndexFiles(index);
  final bytes = await cipher.encrypt(
    key: key,
    accountKey: files.accountKey,
    fileName: 'index.v1.bin',
    plaintext: plain,
    plaintextLimit: readCacheIndexLimit,
  );
  files.requireIndexFiles(index);
  return files.stage(
    'index.v1.bin',
    bytes,
    plaintextBytes: plain.length,
    index: index,
  );
};

// Keep isolate closures outside the store instance: root callbacks and any
// future coordinator/lease captured by them must stay on the owning isolate.
Future<T> _background<T>(
  String root,
  String accountKey,
  DateTime now,
  void Function(ReadCacheFileCheckpoint)? checkpoint,
  List<int> key,
  Future<T> Function(_Files, List<int>) action,
) => Isolate.run(
  () => _guard(() => action(_Files(root, accountKey, now, checkpoint), key)),
);

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on ReadCacheFileException {
    rethrow;
  } on ReadCacheCodecException {
    rethrow;
  } on Object {
    throw const ReadCacheFileException(ReadCacheFileFailure.io);
  }
}

T _guardSync<T>(T Function() action) {
  try {
    return action();
  } on ReadCacheFileException {
    rethrow;
  } on ReadCacheCodecException {
    rethrow;
  } on Object {
    throw const ReadCacheFileException(ReadCacheFileFailure.io);
  }
}

final class _StagedFile {
  const _StagedFile({
    required this.root,
    required this.accountKey,
    required this.accountName,
    required this.now,
    required this.fileName,
    required this.temporaryPath,
    required this.plaintextBytes,
    required this.ciphertextBytes,
    this.index,
  });

  final String root, accountKey, accountName, fileName, temporaryPath;
  final DateTime now;
  final int plaintextBytes, ciphertextBytes;
  final ReadCacheIndex? index;

  // The account hash is prepared in the background, never during commit.
  _Files get files =>
      _Files(root, accountKey, now, null, accountName: accountName);
}

bool readCacheEntryExpired(DateTime fetchedAt, DateTime now) {
  final age = now.toUtc().difference(fetchedAt.toUtc());
  return age.isNegative || age >= readCacheRetention;
}

final _entryPattern = RegExp(r'^e_[0-9a-f]{32}\.v1\.bin$');
final _accountPattern = RegExp(r'^[0-9a-f]{32}$');
final _tempPattern = RegExp(
  r'^(?:e_[0-9a-f]{32}\.v1\.bin|index\.v1\.bin)\.[0-9a-f]{32}\.tmp$',
);

final class _Files {
  _Files(
    this.root,
    this.accountKey,
    this.now,
    this.checkpoint, {
    String? accountName,
  }) : accountName =
           accountName ?? ReadCacheCipher.accountDirectoryName(accountKey);
  final String root, accountKey;
  final String accountName;
  final DateTime now;
  final void Function(ReadCacheFileCheckpoint)? checkpoint;
  String get base => '$root/read_cache';
  String get account => '$base/$accountName';

  FileSystemEntityType type(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  void requireDirectory(String path) {
    if (type(path) != FileSystemEntityType.directory) {
      throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
    }
  }

  void requireFile(String path, {bool absentAllowed = false}) {
    final found = type(path);
    if (found != FileSystemEntityType.file &&
        !(absentAllowed && found == FileSystemEntityType.notFound)) {
      throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
    }
  }

  void confirmAbsent(String path) {
    final directory = Directory(path);
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw const ReadCacheFileException(ReadCacheFileFailure.io);
    }
    // The trusted root may itself have missing ancestors. Confirm their absence
    // too: typeSync reports notFound for permission and other stat failures.
    if (type(parent.path) == FileSystemEntityType.notFound) {
      confirmAbsent(parent.path);
      return;
    }
    final name = directory.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    for (final entity in parent.listSync(followLinks: false)) {
      if (entity.uri.pathSegments.where((part) => part.isNotEmpty).last ==
          name) {
        throw const ReadCacheFileException(ReadCacheFileFailure.io);
      }
    }
  }

  bool directories({bool create = false, bool includeAccount = true}) {
    for (final path in [root, base, if (includeAccount) account]) {
      if (type(path) == FileSystemEntityType.notFound) {
        confirmAbsent(path);
        if (!create) return false;
        // Only the injected trusted root may have missing ancestors.
        Directory(path).createSync(recursive: path == root);
      }
      requireDirectory(path);
    }
    return true;
  }

  void requireName(String name, {bool index = true}) {
    if (!_entryPattern.hasMatch(name) && !(index && name == 'index.v1.bin')) {
      throw const ReadCacheFileException(ReadCacheFileFailure.invalidName);
    }
  }

  Uint8List? read(String name, int plaintextLimit) {
    requireName(name);
    if (!directories()) return null;
    final path = '$account/$name';
    if (type(path) == FileSystemEntityType.notFound) return null;
    requireFile(path);
    final file = File(path);
    final limit = plaintextLimit + readCacheEnvelopeOverhead;
    if (file.lengthSync() > limit) {
      throw const ReadCacheFileException(ReadCacheFileFailure.tooLarge);
    }
    checkpoint?.call(ReadCacheFileCheckpoint.beforeRead);
    directories();
    requireFile(path);
    final handle = file.openSync();
    try {
      if (handle.lengthSync() > limit) {
        throw const ReadCacheFileException(ReadCacheFileFailure.tooLarge);
      }
      final bytes = handle.readSync(limit + 1);
      if (bytes.length > limit || handle.lengthSync() > limit) {
        throw const ReadCacheFileException(ReadCacheFileFailure.tooLarge);
      }
      return bytes;
    } finally {
      handle.closeSync();
    }
  }

  Future<ProjectedDiskEntry?> readEntry(
    List<int> key,
    String name, {
    String? expectedCanonicalKey,
    ReadCacheBodyKind? expectedBodyKind,
  }) async {
    requireName(name, index: false);
    final plaintextLimit = switch (expectedBodyKind) {
      null || ReadCacheBodyKind.terminalLog => readCacheTerminalLogLimit,
      _ => readCacheEntryLimit,
    };
    final bytes = read(name, plaintextLimit);
    if (bytes == null) return null;
    const cipher = ReadCacheCipher();
    final plain = await cipher.decrypt(
      key: key,
      accountKey: accountKey,
      fileName: name,
      envelope: bytes,
      plaintextLimit: plaintextLimit,
    );
    // Only authenticated metadata is inspected. The codec rechecks framing,
    // the entire schema and the smaller per-body limit before returning data.
    var canonicalKey = expectedCanonicalKey;
    if (canonicalKey == null) {
      try {
        if (plain.length < readCacheMetadataLengthBytes) {
          throw const FormatException();
        }
        final size = ByteData.sublistView(plain).getUint32(0);
        if (size > plain.length - readCacheMetadataLengthBytes) {
          throw const FormatException();
        }
        final metadata = jsonDecode(utf8.decode(plain.sublist(4, 4 + size)));
        if (metadata is! Map<String, Object?> ||
            metadata['canonicalKey'] is! String) {
          throw const FormatException();
        }
        canonicalKey = metadata['canonicalKey']! as String;
      } on Object {
        throw const ReadCacheCodecException(ReadCacheCodecError.malformed);
      }
    }
    final entry = cipher.decodeEntry(
      plain,
      accountKey: accountKey,
      canonicalKey: canonicalKey,
    );
    if (expectedBodyKind != null && entry.bodyKind != expectedBodyKind) {
      throw const ReadCacheCodecException(ReadCacheCodecError.bindingMismatch);
    }
    if (await cipher.entryFileName(key, entry.canonicalKey) != name) {
      throw const ReadCacheFileException(ReadCacheFileFailure.invalidName);
    }
    return readCacheEntryExpired(entry.fetchedAt, now) ? null : entry;
  }

  List<String> entryFiles() {
    if (!directories()) return const [];
    final names = <String>[];
    for (final entity in Directory(account).listSync(followLinks: false)) {
      requireFile(entity.path);
      final name = entity.uri.pathSegments.last;
      if (_entryPattern.hasMatch(name)) names.add(name);
    }
    names.sort();
    return names;
  }

  bool indexFileExists(
    ReadCacheIndexEntry entry, {
    bool chainVerified = false,
  }) {
    requireName(entry.fileName, index: false);
    if (!chainVerified && !directories()) return false;
    final path = '$account/${entry.fileName}';
    final found = type(path);
    if (found == FileSystemEntityType.notFound) return false;
    if (chainVerified) {
      // Reuse only the same synchronous commit's ancestor check. Each reference
      // still needs its own non-following type check and length check.
      if (found != FileSystemEntityType.file) {
        throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
      }
    } else {
      requireFile(path);
    }
    return File(path).lengthSync() == entry.sizeBytes;
  }

  void requireIndexFiles(ReadCacheIndex index, {bool chainVerified = false}) {
    for (final entry in index.entries) {
      if (!indexFileExists(entry, chainVerified: chainVerified)) {
        throw const ReadCacheFileException(ReadCacheFileFailure.io);
      }
    }
  }

  _StagedFile stage(
    String name,
    List<int> bytes, {
    required int plaintextBytes,
    ReadCacheIndex? index,
  }) {
    requireName(name);
    final total = usage();
    // Peak capacity includes the complete new temporary plus the old target.
    if (total.accountBytes + bytes.length > readCacheAccountByteLimit ||
        total.deviceBytes + bytes.length > readCacheDeviceByteLimit) {
      throw const ReadCacheFileException(ReadCacheFileFailure.capacity);
    }
    directories(create: true);
    final path = '$account/$name';
    requireFile(path, absentAllowed: true);
    final random = Random.secure();
    File? temporary;
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final candidate = File('$path.$suffix.tmp');
      try {
        candidate.createSync(exclusive: true);
        temporary = candidate;
        break;
      } on FileSystemException {
        if (type(candidate.path) != FileSystemEntityType.notFound) continue;
        rethrow;
      }
    }
    if (temporary == null) {
      throw const ReadCacheFileException(ReadCacheFileFailure.io);
    }
    var interrupted = false;
    var staged = false;
    void check(ReadCacheFileCheckpoint step) {
      try {
        checkpoint?.call(step);
      } on Object {
        interrupted = true;
        rethrow;
      }
    }

    try {
      // Only checkpoint-simulated crashes leave ciphertext-only temporaries.
      check(ReadCacheFileCheckpoint.temporaryCreated);
      directories();
      requireFile(temporary.path);
      final handle = temporary.openSync(mode: FileMode.writeOnly);
      try {
        handle.writeFromSync(bytes);
        check(ReadCacheFileCheckpoint.temporaryWritten);
        handle.flushSync();
        check(ReadCacheFileCheckpoint.temporaryFlushed);
      } finally {
        handle.closeSync();
      }
      check(
        name == 'index.v1.bin'
            ? ReadCacheFileCheckpoint.beforeIndexRename
            : ReadCacheFileCheckpoint.beforeEntryRename,
      );
      staged = true;
      return _StagedFile(
        root: root,
        accountKey: accountKey,
        accountName: accountName,
        now: now,
        fileName: name,
        temporaryPath: temporary.path,
        plaintextBytes: plaintextBytes,
        ciphertextBytes: bytes.length,
        index: index,
      );
    } finally {
      if (!staged && !interrupted) deleteTemporary(temporary.path);
    }
  }

  void deleteTemporary(String path) {
    // Recheck ancestors before cleanup so replaced links cannot escape root.
    if (!directories()) return;
    switch (type(path)) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.file:
        File(path).deleteSync();
      case FileSystemEntityType.link:
        Link(path).deleteSync();
      default:
        throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
    }
  }

  void deleteEntry(String name) {
    requireName(name, index: false);
    if (!directories()) return;
    final path = '$account/$name';
    final found = type(path);
    if (found == FileSystemEntityType.notFound) return;
    if (found == FileSystemEntityType.link) {
      Link(path).deleteSync();
    } else {
      requireFile(path);
      File(path).deleteSync();
    }
  }

  int removeStaleTemporary() {
    if (!directories()) return 0;
    var removed = 0;
    for (final entity in Directory(account).listSync(followLinks: false)) {
      requireFile(entity.path);
      if (!_tempPattern.hasMatch(entity.uri.pathSegments.last)) continue;
      if (now.difference(File(entity.path).lastModifiedSync().toUtc()) >
          readCacheTemporaryRetention) {
        File(entity.path).deleteSync();
        removed++;
      }
    }
    return removed;
  }

  List<String> accountDirectoryNames() {
    if (!directories(includeAccount: false)) return const [];
    final names = <String>[];
    for (final directory in Directory(base).listSync(followLinks: false)) {
      requireDirectory(directory.path);
      final segment = directory.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (!_accountPattern.hasMatch(segment)) {
        throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
      }
      names.add(segment);
    }
    names.sort();
    return names;
  }

  ReadCacheDirectoryState accountDirectoryState() {
    if (!directories()) return ReadCacheDirectoryState.absent;
    var hasFiles = false;
    for (final entity in Directory(account).listSync(followLinks: false)) {
      requireFile(entity.path);
      hasFiles = true;
    }
    return hasFiles
        ? ReadCacheDirectoryState.hasFiles
        : ReadCacheDirectoryState.emptyDirectory;
  }

  void clearAccountDirectoriesExcept(Set<String> retainedNames) {
    final names = accountDirectoryNames();
    for (final name in names) {
      if (retainedNames.contains(name)) continue;
      requireDirectory(root);
      requireDirectory(base);
      deleteNode('$base/$name');
    }
  }

  ReadCacheFileUsage usage() {
    var accountBytes = 0;
    var deviceBytes = 0;
    for (final name in accountDirectoryNames()) {
      final path = '$base/$name';
      requireDirectory(path);
      for (final entity in Directory(path).listSync(followLinks: false)) {
        requireFile(entity.path);
        final size = File(entity.path).lengthSync();
        deviceBytes += size;
        if (path == account) accountBytes += size;
      }
    }
    return ReadCacheFileUsage(
      accountBytes: accountBytes,
      deviceBytes: deviceBytes,
    );
  }

  void clear({required bool all}) {
    if (type(root) == FileSystemEntityType.notFound) return;
    requireDirectory(root);
    if (type(base) == FileSystemEntityType.notFound) return;
    if (all || type(base) == FileSystemEntityType.link) {
      deleteNode(base);
      return;
    }
    requireDirectory(base);
    deleteNode(account);
  }

  void deleteNode(String path) {
    switch (type(path)) {
      case FileSystemEntityType.notFound:
        return;
      case FileSystemEntityType.link:
        Link(path).deleteSync();
      case FileSystemEntityType.file:
        File(path).deleteSync();
      case FileSystemEntityType.directory:
        for (final entity in Directory(path).listSync(followLinks: false)) {
          deleteNode(entity.path);
        }
        requireDirectory(path);
        Directory(path).deleteSync();
      default:
        throw const ReadCacheFileException(ReadCacheFileFailure.untrustedPath);
    }
  }
}
