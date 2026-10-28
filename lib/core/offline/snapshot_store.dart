import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'snapshot_schema.dart';

/// Derived keys only. The root key must not be sent to a worker isolate.
final class SnapshotKeyMaterial {
  SnapshotKeyMaterial._(List<int> data, List<int> names)
    : data = Uint8List.fromList(data),
      names = Uint8List.fromList(names);
  final Uint8List data;
  final Uint8List names;

  static Future<SnapshotKeyMaterial> derive(List<int> rootKey) async {
    if (rootKey.length != 32 || rootKey.any((b) => b < 0 || b > 255)) {
      throw const SnapshotStoreException(SnapshotStoreError.invalidKey);
    }
    final hkdf = DartHkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<List<int>> derive(String info) async => (await hkdf.deriveKey(
      secretKey: SecretKey(rootKey),
      nonce: utf8.encode('mergeline-offline-repo'),
      info: utf8.encode(info),
    )).extractBytes();
    return SnapshotKeyMaterial._(
      await derive('offline-repo-data-v1'),
      await derive('offline-repo-names-v1'),
    );
  }
}

enum SnapshotStoreError {
  invalidKey,
  untrustedPath,
  invalidName,
  tooLarge,
  capacity,
  io,
  deviceFull,
  authenticationFailed,
  newerSchema,
  revoked,
  revisionConflict,
  corrupt,
}

final class SnapshotStoreException implements Exception {
  const SnapshotStoreException(this.code);
  final SnapshotStoreError code;
  @override
  String toString() => 'SnapshotStoreException(${code.name})';
}

enum SnapshotStoreCheckpoint {
  temporaryWritten,
  temporaryFlushed,
  beforeRename,
  renamed,
}

/// The coordinator serializes index/tree/recovery/GC and owns the live fences.
/// Every mutation requires a live commit predicate; no network or key storage is
/// performed here. A worker may construct this with derived keys only.
final class SnapshotStore {
  SnapshotStore({
    required Directory supportRoot,
    required this.accountKey,
    required List<int> rootKey,
    this.checkpoint,
    this.mayMutate,
  }) : _root = supportRoot.absolute.path,
       _keys = SnapshotKeyMaterial.derive(List<int>.of(rootKey));
  SnapshotStore.withKeys({
    required Directory supportRoot,
    required this.accountKey,
    required SnapshotKeyMaterial keys,
    this.checkpoint,
    this.mayMutate,
  }) : _root = supportRoot.absolute.path,
       _keys = Future.value(keys);

  final String _root, accountKey;
  final Future<SnapshotKeyMaterial> _keys;
  final void Function(SnapshotStoreCheckpoint)? checkpoint;
  final bool Function()? mayMutate;

  bool _canMutate(bool Function() mayCommit) =>
      (mayMutate?.call() ?? true) && mayCommit();
  int _revision = 0;
  int get revision => _revision;
  Directory get supportRoot => Directory(_root);
  Future<SnapshotKeyMaterial> get workerKeys async {
    if (!(mayMutate?.call() ?? true)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    final keys = await _keys;
    if (!(mayMutate?.call() ?? true)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    return keys;
  }

  String get _base => '$_root/offline_repo';
  String get accountDirectory =>
      '$_base/${crypto.sha256.convert(utf8.encode(accountKey)).toString().substring(0, 32)}';
  String get _blobs => '$accountDirectory/b';
  String get _tmp => '$accountDirectory/tmp';
  static final _treeName = RegExp(r'^t_[a-f0-9]{32}\.v1\.bin$');
  static final _blobName = RegExp(r'^b/[a-f0-9]{32}\.v1\.bin$');

  static String treeFileName(String id) {
    if (!validSnapshotId(id)) {
      throw const SnapshotStoreException(SnapshotStoreError.invalidName);
    }
    return 't_$id.v1.bin';
  }

  Future<String> blobFileName(SnapshotObjectFormat format, String id) async {
    if (!validObjectId(id, format)) {
      throw const SnapshotStoreException(SnapshotStoreError.invalidName);
    }
    final keys = await _keys;
    final digest = crypto.Hmac(
      crypto.sha256,
      keys.names,
    ).convert(utf8.encode('${format.name}:$id')).toString().substring(0, 32);
    return 'b/$digest.v1.bin';
  }

  Future<Uint8List> _encrypt(String name, List<int> plain) async {
    final keys = await _keys;
    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
    final box = await DartAesGcm(secretKeyLength: 32).encrypt(
      plain,
      secretKey: SecretKey(keys.data),
      nonce: nonce,
      aad: _aad(name),
    );
    final builder = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return builder.takeBytes();
  }

  Future<Uint8List> _decrypt(String name, Uint8List bytes, int maxPlain) async {
    if (bytes.length < snapshotEnvelopeOverhead) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    if (bytes.length > maxPlain + snapshotEnvelopeOverhead) {
      throw const SnapshotStoreException(SnapshotStoreError.tooLarge);
    }
    if (bytes.first > 1) {
      throw const SnapshotStoreException(SnapshotStoreError.newerSchema);
    }
    if (bytes.first != 1) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    try {
      final keys = await _keys;
      final box = SecretBox.fromConcatenation(
        bytes.sublist(1),
        nonceLength: 12,
        macLength: 16,
      );
      final decoded = await DartAesGcm(
        secretKeyLength: 32,
      ).decrypt(box, secretKey: SecretKey(keys.data), aad: _aad(name));
      return Uint8List.fromList(decoded);
    } on SnapshotStoreException {
      rethrow;
    } catch (_) {
      throw const SnapshotStoreException(
        SnapshotStoreError.authenticationFailed,
      );
    }
  }

  List<int> _aad(String name) =>
      utf8.encode(jsonEncode(['offline_repo', 1, accountKey, name]));
  void _confirmAbsent(String path) {
    final parent = File(path).parent;
    if (parent.path == path) {
      throw const SnapshotStoreException(SnapshotStoreError.io);
    }
    if (FileSystemEntity.typeSync(parent.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      _confirmAbsent(parent.path);
      return;
    }
    if (FileSystemEntity.typeSync(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
    }
    final name = path.split(Platform.pathSeparator).last;
    if (parent
        .listSync(followLinks: false)
        .any(
          (entity) => entity.path.split(Platform.pathSeparator).last == name,
        )) {
      throw const SnapshotStoreException(SnapshotStoreError.io);
    }
  }

  bool _directory(String path, {required bool create}) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _confirmAbsent(path);
      if (!create) return false;
      Directory(path).createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
    }
    return true;
  }

  bool _chain({
    required bool create,
    bool blobs = false,
    bool temporary = false,
  }) {
    if (!_directory(_root, create: false)) {
      throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
    }
    if (!_directory(_base, create: create) ||
        !_directory(accountDirectory, create: create)) {
      return false;
    }
    if (blobs && !_directory(_blobs, create: create)) return false;
    if (temporary && !_directory(_tmp, create: create)) return false;
    return true;
  }

  void _regular(String path, {bool absentAllowed = false}) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        !(absentAllowed && type == FileSystemEntityType.notFound)) {
      throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
    }
  }

  void _name(String name) {
    if (name != 'index.v1.bin' &&
        !_treeName.hasMatch(name) &&
        !_blobName.hasMatch(name)) {
      throw const SnapshotStoreException(SnapshotStoreError.invalidName);
    }
  }

  Uint8List? _readFile(String name, int maxPlain) {
    _name(name);
    if (!_chain(create: false, blobs: name.startsWith('b/'))) return null;
    final path = '$accountDirectory/$name';
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _confirmAbsent(path);
      return null;
    }
    _regular(path);
    final file = File(path);
    if (file.lengthSync() > maxPlain + snapshotEnvelopeOverhead) {
      throw const SnapshotStoreException(SnapshotStoreError.tooLarge);
    }
    return file.readAsBytesSync();
  }

  int usage() {
    if (!_chain(create: false)) return 0;
    int walk(Directory directory) {
      var total = 0;
      for (final entity in directory.listSync(followLinks: false)) {
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.file) {
          total += File(entity.path).lengthSync();
        } else if (type == FileSystemEntityType.directory) {
          total += walk(Directory(entity.path));
        } else {
          throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
        }
      }
      return total;
    }

    return walk(Directory(accountDirectory));
  }

  String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool _matchesFile(String path, Uint8List expected) {
    final file = File(path).openSync(mode: FileMode.read);
    try {
      if (file.lengthSync() != expected.length) return false;
      var offset = 0;
      while (offset < expected.length) {
        final remaining = expected.length - offset;
        final chunk = file.readSync(remaining > 65536 ? 65536 : remaining);
        if (chunk.isEmpty) return false;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != expected[offset + i]) return false;
        }
        offset += chunk.length;
      }
      return true;
    } finally {
      file.closeSync();
    }
  }

  /// The live guard and revision compare are synchronous with the rename.
  void _commit(
    String name,
    Uint8List ciphertext,
    bool Function() mayCommit, {
    int? expectedRevision,
  }) {
    _name(name);
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    String? tempPath;
    String? jobPath;
    try {
      _chain(create: true, blobs: name.startsWith('b/'), temporary: true);
      if (usage() + ciphertext.length > snapshotAccountLimit) {
        throw const SnapshotStoreException(SnapshotStoreError.capacity);
      }
      jobPath = '$_tmp/${_randomId()}';
      if (FileSystemEntity.typeSync(jobPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
      }
      Directory(jobPath).createSync();
      tempPath = '$jobPath/data';
      final file = File(tempPath)..createSync(exclusive: true);
      final temp = file.openSync(mode: FileMode.writeOnly);
      try {
        temp.writeFromSync(ciphertext);
        checkpoint?.call(SnapshotStoreCheckpoint.temporaryWritten);
        temp.flushSync();
        checkpoint?.call(SnapshotStoreCheckpoint.temporaryFlushed);
      } finally {
        temp.closeSync();
      }
      _chain(create: false, blobs: name.startsWith('b/'), temporary: true);
      if (FileSystemEntity.typeSync(jobPath, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
      }
      _regular(tempPath);
      final target = '$accountDirectory/$name';
      _regular(target, absentAllowed: true);
      if (usage() > snapshotAccountLimit) {
        throw const SnapshotStoreException(SnapshotStoreError.capacity);
      }
      checkpoint?.call(SnapshotStoreCheckpoint.beforeRename);
      _chain(create: false, blobs: name.startsWith('b/'), temporary: true);
      if (FileSystemEntity.typeSync(jobPath, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
      }
      _regular(tempPath);
      _regular(target, absentAllowed: true);
      if (!_matchesFile(tempPath, ciphertext)) {
        throw const SnapshotStoreException(SnapshotStoreError.corrupt);
      }
      if (usage() > snapshotAccountLimit) {
        throw const SnapshotStoreException(SnapshotStoreError.capacity);
      }
      if (!_canMutate(mayCommit)) {
        throw const SnapshotStoreException(SnapshotStoreError.revoked);
      }
      if (expectedRevision != null && expectedRevision != _revision) {
        throw const SnapshotStoreException(SnapshotStoreError.revisionConflict);
      }
      File(tempPath).renameSync(target);
      tempPath = null;
      if (name == 'index.v1.bin') _revision++;
      checkpoint?.call(SnapshotStoreCheckpoint.renamed);
    } on FileSystemException catch (e) {
      throw SnapshotStoreException(
        e.osError?.errorCode == 28
            ? SnapshotStoreError.deviceFull
            : SnapshotStoreError.io,
      );
    } finally {
      // Never traverse a substituted directory while discarding a temp file.
      if (jobPath != null && _safeTempChain(jobPath)) {
        if (tempPath != null &&
            FileSystemEntity.typeSync(tempPath, followLinks: false) ==
                FileSystemEntityType.file) {
          File(tempPath).deleteSync();
        }
        if (Directory(jobPath).listSync(followLinks: false).isEmpty) {
          Directory(jobPath).deleteSync();
        }
      }
    }
  }

  bool _safeTempChain(String jobPath) {
    for (final path in [_root, _base, accountDirectory, _tmp, jobPath]) {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return false;
      }
    }
    return true;
  }

  Future<SnapshotIndex?> readIndex() async {
    final bytes = _readFile('index.v1.bin', snapshotIndexLimit);
    if (bytes == null) return null;
    return SnapshotIndex.decode(
      await _decrypt('index.v1.bin', bytes, snapshotIndexLimit),
      accountKey: accountKey,
    );
  }

  Future<void> writeIndex(
    SnapshotIndex index, {
    required int expectedRevision,
    required bool Function() mayCommit,
  }) async {
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    if (index.accountKey != accountKey) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    final plain = index.encode();
    // Only newly published or materially changed complete entries need their
    // entire tree checked. Existing entries may have lost a blob since their
    // publication; that damage must not prevent unrelated metadata, removal,
    // or a replacement save from being committed. Probe metadata does not
    // change the published snapshot identity or contents.
    final previous = await readIndex();
    final completed = <String, SnapshotRecord>{
      for (final record in previous?.snapshots ?? const <SnapshotRecord>[])
        if (record.status == SnapshotStatus.complete) record.id: record,
    };
    String publication(SnapshotRecord record) {
      final fields = record.toJson()
        ..remove('headSha')
        ..remove('probe')
        ..remove('probedAt');
      return jsonEncode(fields);
    }

    // New complete entries may only reference a readable final tree and
    // present regular blob files. Hash and AEAD are rechecked when blobs open.
    for (final record in index.snapshots) {
      if (record.status != SnapshotStatus.complete) continue;
      final prior = completed[record.id];
      if (prior != null && publication(prior) == publication(record)) continue;
      final tree = await readTree(record);
      if (tree == null) {
        throw const SnapshotStoreException(SnapshotStoreError.corrupt);
      }
      for (final entry in tree.entries) {
        if (entry.type != SnapshotEntryType.blob ||
            entry.state != SnapshotEntryState.saved) {
          continue;
        }
        final name = await blobFileName(record.objectFormat, entry.id);
        if (!_chain(create: false, blobs: true)) {
          throw const SnapshotStoreException(SnapshotStoreError.corrupt);
        }
        final path = '$accountDirectory/$name';
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          _confirmAbsent(path);
          throw const SnapshotStoreException(SnapshotStoreError.corrupt);
        }
        _regular(path);
        if (File(path).lengthSync() >
            snapshotBlobLimit + snapshotEnvelopeOverhead) {
          throw const SnapshotStoreException(SnapshotStoreError.tooLarge);
        }
      }
    }
    final encoded = await _encrypt('index.v1.bin', plain);
    SnapshotIndex.decode(
      await _decrypt('index.v1.bin', encoded, snapshotIndexLimit),
      accountKey: accountKey,
    );
    _commit(
      'index.v1.bin',
      encoded,
      mayCommit,
      expectedRevision: expectedRevision,
    );
    if (await readIndex() == null) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
  }

  Future<SnapshotTree?> readTree(SnapshotRecord record) async {
    final name = treeFileName(record.id);
    final bytes = _readFile(name, snapshotTreeLimit);
    if (bytes == null) return null;
    return SnapshotTree.decode(
      await _decrypt(name, bytes, snapshotTreeLimit),
      format: record.objectFormat,
      snapshotId: record.id,
      sha: record.sha,
      subPath: record.subPath,
      complete: record.status == SnapshotStatus.complete,
    );
  }

  /// Check a completed snapshot before deciding a same-version save is a
  /// no-op. Missing or corrupt content is repairable; untrusted paths and
  /// unavailable storage remain errors and must not be treated as absence.
  Future<bool> hasReadableSnapshot(SnapshotRecord record) async {
    try {
      final tree = await readTree(record);
      if (tree == null) return false;
      for (final entry in tree.entries) {
        if (entry.type != SnapshotEntryType.blob ||
            entry.state != SnapshotEntryState.saved) {
          continue;
        }
        final bytes = await readBlob(record.objectFormat, entry.id);
        if (bytes == null || bytes.length != entry.size) return false;
      }
      return true;
    } on SnapshotStoreException catch (error) {
      if (error.code == SnapshotStoreError.corrupt ||
          error.code == SnapshotStoreError.authenticationFailed ||
          error.code == SnapshotStoreError.tooLarge) {
        return false;
      }
      rethrow;
    } on SnapshotSchemaException catch (error) {
      if (error.code == SnapshotSchemaError.newerSchema) rethrow;
      return false;
    }
  }

  Future<void> writeTree(
    SnapshotTree tree, {
    required SnapshotObjectFormat format,
    required bool complete,
    required bool Function() mayCommit,
  }) async {
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    final name = treeFileName(tree.snapshotId);
    final encoded = await _encrypt(
      name,
      tree.encode(format: format, complete: complete),
    );
    SnapshotTree.decode(
      await _decrypt(name, encoded, snapshotTreeLimit),
      format: format,
      snapshotId: tree.snapshotId,
      sha: tree.sha,
      subPath: tree.subPath,
      complete: complete,
    );
    _commit(name, encoded, mayCommit);
    final reread = _readFile(name, snapshotTreeLimit);
    if (reread == null) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    SnapshotTree.decode(
      await _decrypt(name, reread, snapshotTreeLimit),
      format: format,
      snapshotId: tree.snapshotId,
      sha: tree.sha,
      subPath: tree.subPath,
      complete: complete,
    );
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
  }

  static String _objectId(SnapshotObjectFormat format, List<int> bytes) {
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode('blob ${bytes.length}\u0000'))
      ..add(bytes);
    return (format == SnapshotObjectFormat.sha1 ? crypto.sha1 : crypto.sha256)
        .convert(payload.takeBytes())
        .toString();
  }

  Future<Uint8List?> readBlob(SnapshotObjectFormat format, String id) async {
    final name = await blobFileName(format, id);
    final bytes = _readFile(name, snapshotBlobLimit);
    if (bytes == null) return null;
    final plain = await _decrypt(name, bytes, snapshotBlobLimit);
    if (_objectId(format, plain) != id) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    return plain;
  }

  /// Returns true if an authenticated, hash-matching existing blob was reused.
  Future<bool> writeBlob(
    SnapshotObjectFormat format,
    String id,
    List<int> bytes, {
    required bool Function() mayCommit,
  }) async {
    if (bytes.length > snapshotBlobLimit) {
      throw const SnapshotStoreException(SnapshotStoreError.tooLarge);
    }
    if (_objectId(format, bytes) != id) {
      throw const SnapshotStoreException(SnapshotStoreError.corrupt);
    }
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    final name = await blobFileName(format, id);
    try {
      final existing = await readBlob(format, id);
      if (existing != null) {
        if (!_canMutate(mayCommit)) {
          throw const SnapshotStoreException(SnapshotStoreError.revoked);
        }
        return true;
      }
    } on SnapshotStoreException catch (e) {
      if (e.code != SnapshotStoreError.authenticationFailed &&
          e.code != SnapshotStoreError.corrupt &&
          e.code != SnapshotStoreError.tooLarge) {
        rethrow;
      }
    }
    final encoded = await _encrypt(name, bytes);
    _commit(name, encoded, mayCommit);
    return false;
  }

  void deleteTree(String id, {required bool Function() mayCommit}) {
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    final name = treeFileName(id);
    if (!_chain(create: false)) return;
    final path = '$accountDirectory/$name';
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    _regular(path);
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    File(path).deleteSync();
  }

  void _removeTemps(bool Function() mayCommit) {
    if (!_chain(create: false, temporary: true)) return;
    void remove(Directory dir) {
      for (final entity in dir.listSync(followLinks: false)) {
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          remove(Directory(entity.path));
          if (!_canMutate(mayCommit)) {
            throw const SnapshotStoreException(SnapshotStoreError.revoked);
          }
          Directory(entity.path).deleteSync();
        } else if (type == FileSystemEntityType.file) {
          if (!_canMutate(mayCommit)) {
            throw const SnapshotStoreException(SnapshotStoreError.revoked);
          }
          File(entity.path).deleteSync();
        } else {
          throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
        }
      }
    }

    for (final entity in Directory(_tmp).listSync(followLinks: false)) {
      final job = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!validSnapshotId(job) ||
          FileSystemEntity.typeSync(entity.path, followLinks: false) !=
              FileSystemEntityType.directory) {
        throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
      }
      remove(Directory(entity.path));
      if (!_canMutate(mayCommit)) {
        throw const SnapshotStoreException(SnapshotStoreError.revoked);
      }
      Directory(entity.path).deleteSync();
    }
  }

  /// Caller holds the account maintenance lock and has drained every worker.
  /// A newer schema or unreadable root aborts before any blob is deleted.
  Future<SnapshotIndex?> recover({
    required DateTime now,
    required bool workersRunning,
    required bool Function() mayCommit,
  }) async {
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    if (workersRunning) return readIndex();
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    final current = await readIndex();
    if (current == null) {
      _removeTemps(mayCommit);
      _sweepBlobs(const <String>{}, mayCommit);
      return null;
    }
    // Inspect every referenced tree for a newer version before touching files.
    final trees = <String, SnapshotTree?>{};
    for (final record in current.snapshots) {
      if (!_canMutate(mayCommit)) {
        throw const SnapshotStoreException(SnapshotStoreError.revoked);
      }
      try {
        trees[record.id] = await readTree(record);
      } on SnapshotStoreException catch (e) {
        if (e.code == SnapshotStoreError.newerSchema ||
            e.code == SnapshotStoreError.untrustedPath ||
            e.code == SnapshotStoreError.io) {
          rethrow;
        }
        trees[record.id] = null;
      } on SnapshotSchemaException catch (e) {
        if (e.code == SnapshotSchemaError.newerSchema) rethrow;
        trees[record.id] = null;
      }
    }
    _removeTemps(mayCommit);
    final kept = <SnapshotRecord>[];
    var removed = 0;
    var changed = false;
    for (final record in current.snapshots) {
      if (!_canMutate(mayCommit)) {
        throw const SnapshotStoreException(SnapshotStoreError.revoked);
      }
      if (record.status == SnapshotStatus.superseded) {
        deleteTree(record.id, mayCommit: mayCommit);
        changed = true;
        continue;
      }
      final tree = trees[record.id];
      final stale =
          record.status != SnapshotStatus.complete &&
          now.toUtc().difference(record.createdAt.toUtc()) >
              const Duration(hours: 24);
      if (tree == null || stale) {
        deleteTree(record.id, mayCommit: mayCommit);
        if (record.status == SnapshotStatus.complete) removed++;
        changed = true;
      } else if (record.status == SnapshotStatus.saving) {
        kept.add(
          record.copyWith(status: SnapshotStatus.paused, interrupted: true),
        );
        changed = true;
      } else {
        kept.add(record);
      }
    }
    var result = current;
    if (changed) {
      final prior = current.removedNotice?.count ?? 0;
      result = current.copyWith(
        snapshots: kept,
        gcPending: true,
        removedNotice: removed > 0
            ? SnapshotRemovedNotice(prior + removed, now.toUtc())
            : null,
      );
      await writeIndex(
        result,
        expectedRevision: revision,
        mayCommit: mayCommit,
      );
    }
    if (result.gcPending) {
      result = await collectGarbage(result, mayCommit: mayCommit);
    }
    return result;
  }

  /// Must run under the same maintenance lock with no worker registered.
  Future<SnapshotIndex> collectGarbage(
    SnapshotIndex index, {
    required bool Function() mayCommit,
  }) async {
    if (!_canMutate(mayCommit)) {
      throw const SnapshotStoreException(SnapshotStoreError.revoked);
    }
    final keep = <String>{};
    for (final record in index.snapshots) {
      if (!_canMutate(mayCommit)) {
        throw const SnapshotStoreException(SnapshotStoreError.revoked);
      }
      final tree = await readTree(record);
      if (tree == null) {
        throw const SnapshotStoreException(SnapshotStoreError.corrupt);
      }
      for (final entry in tree.entries) {
        if (entry.type == SnapshotEntryType.blob &&
            (record.status != SnapshotStatus.complete ||
                entry.state == SnapshotEntryState.saved)) {
          keep.add(await blobFileName(record.objectFormat, entry.id));
        }
      }
    }
    _sweepBlobs(keep, mayCommit);
    final next = index.copyWith(gcPending: false);
    await writeIndex(next, expectedRevision: revision, mayCommit: mayCommit);
    return next;
  }

  void _sweepBlobs(Set<String> keep, bool Function() mayCommit) {
    if (_chain(create: false, blobs: true)) {
      for (final entity in Directory(_blobs).listSync(followLinks: false)) {
        final filename = entity.uri.pathSegments.last;
        final relative = 'b/$filename';
        if (!_blobName.hasMatch(relative)) {
          throw const SnapshotStoreException(SnapshotStoreError.untrustedPath);
        }
        _regular(entity.path);
        if (!keep.contains(relative)) {
          if (!_canMutate(mayCommit)) {
            throw const SnapshotStoreException(SnapshotStoreError.revoked);
          }
          File(entity.path).deleteSync();
        }
      }
    }
  }
}
