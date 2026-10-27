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

/// Fault boundaries execute in the same background isolate as the transaction.
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

/// Atomic, bounded primitives only. The coordinator owns admission, account
/// serialization, leases, markers, key creation, recovery and LRU decisions.
/// Constructing this store performs no I/O and never selects a platform root.
/// An untrustedPath from usage() is device-wide fail-closed. Foreign names and
/// wrong directory types can be cleared with clearRoot(); special files cannot
/// be removed in the app, so the cache stays closed.
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
    // In particular, do not call the root provider, stat or clean temporary
    // files when the secure store cannot supply a key.
    if (key == null) {
      throw const ReadCacheFileException(ReadCacheFileFailure.keyUnavailable);
    }
    if (key.length != 32 || key.any((byte) => byte < 0 || byte > 255)) {
      throw const ReadCacheFileException(ReadCacheFileFailure.invalidKey);
    }
    final keySnapshot = List<int>.of(key);
    final path = await _resolveRoot();
    final now = _clock().toUtc();
    final hook = checkpoint;
    return _background(path, accountKey, now, hook, keySnapshot, action);
  }

  Future<String> writeEntry(ProjectedDiskEntry entry, List<int>? key) =>
      _run(entry.accountKey, key, (files, key) async {
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
        files.atomic(name, bytes);
        return name;
      });

  /// Returns null when missing or expired. The caller evicts on null so expired
  /// files do not remain on disk indefinitely.
  Future<ProjectedDiskEntry?> readEntry(
    String accountKey,
    List<int>? key,
    String canonicalKey,
  ) => _run(accountKey, key, (files, key) async {
    final name = await const ReadCacheCipher().entryFileName(key, canonicalKey);
    return files.readEntry(key, name, expectedCanonicalKey: canonicalKey);
  });

  /// Recovery can authenticate an entry discovered by its opaque file name.
  /// This does not scan, delete, rebuild an index or choose an eviction policy.
  /// Returns null when missing or expired; the caller evicts on null.
  Future<ProjectedDiskEntry?> readEntryFile(
    String accountKey,
    List<int>? key,
    String fileName,
  ) => _run(accountKey, key, (files, key) => files.readEntry(key, fileName));

  Future<List<String>> entryFiles(String accountKey, List<int>? key) =>
      _run(accountKey, key, (files, _) async => files.entryFiles());

  Future<void> writeIndex(
    String accountKey,
    List<int>? key,
    ReadCacheIndex index,
  ) => _run(accountKey, key, (files, key) async {
    const cipher = ReadCacheCipher();
    final plain = cipher.encodeIndex(index);
    // Never publish an index that claims a file not yet committed to disk.
    files.requireIndexFiles(index);
    final bytes = await cipher.encrypt(
      key: key,
      accountKey: accountKey,
      fileName: 'index.v1.bin',
      plaintext: plain,
      plaintextLimit: readCacheIndexLimit,
    );
    files.requireIndexFiles(index);
    files.atomic(
      'index.v1.bin',
      bytes,
      beforeRename: () => files.requireIndexFiles(index),
    );
  });

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
  _Files(this.root, this.accountKey, this.now, this.checkpoint);
  final String root, accountKey;
  final DateTime now;
  final void Function(ReadCacheFileCheckpoint)? checkpoint;
  String get base => '$root/read_cache';
  String get account =>
      '$base/${ReadCacheCipher.accountDirectoryName(accountKey)}';

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
  }) async {
    requireName(name, index: false);
    final bytes = read(name, readCacheTerminalLogLimit);
    if (bytes == null) return null;
    const cipher = ReadCacheCipher();
    final plain = await cipher.decrypt(
      key: key,
      accountKey: accountKey,
      fileName: name,
      envelope: bytes,
      plaintextLimit: readCacheTerminalLogLimit,
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

  bool indexFileExists(ReadCacheIndexEntry entry) {
    requireName(entry.fileName, index: false);
    if (!directories()) return false;
    final path = '$account/${entry.fileName}';
    if (type(path) == FileSystemEntityType.notFound) return false;
    requireFile(path);
    return File(path).lengthSync() == entry.sizeBytes;
  }

  void requireIndexFiles(ReadCacheIndex index) {
    for (final entry in index.entries) {
      if (!indexFileExists(entry)) {
        throw const ReadCacheFileException(ReadCacheFileFailure.io);
      }
    }
  }

  void atomic(String name, List<int> bytes, {void Function()? beforeRename}) {
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
      directories();
      requireFile(temporary.path);
      requireFile(path, absentAllowed: true);
      // Revalidate references in the same synchronous commit section. An entry
      // removed while the encrypted index was being prepared cannot be claimed.
      beforeRename?.call();
      temporary.renameSync(path);
      requireFile(path);
      check(
        name == 'index.v1.bin'
            ? ReadCacheFileCheckpoint.indexRenamed
            : ReadCacheFileCheckpoint.entryRenamed,
      );
    } finally {
      // Recheck ancestors before cleanup so replaced links cannot escape root.
      if (!interrupted && directories()) deleteNode(temporary.path);
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
