import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/ai/ai_display.dart';
import 'ai_history_codec.dart';

Future<Directory> Function() aiHistoryStorageRoot = _defaultRoot;
Future<Directory> _defaultRoot() =>
    Platform.environment.containsKey('FLUTTER_TEST')
    ? Future.value(
        Directory('${Directory.systemTemp.path}/gitlab_mobile_tests_$pid'),
      )
    : getApplicationSupportDirectory();

@visibleForTesting
void Function(Directory) removeAiHistoryDirectory = (directory) =>
    directory.deleteSync(recursive: true);

String aiHistoryAccountSegment(String account) =>
    sha256.convert(utf8.encode(account)).toString().substring(0, 32);

bool validAiConversationId(String id) => RegExp(r'^[0-9a-f]{32}$').hasMatch(id);
String newAiConversationId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _conversationName(String id) {
  if (!validAiConversationId(id)) throw ArgumentError.value(id, 'id');
  return 'c_$id.v1.bin';
}

final class AiSavedConversation {
  const AiSavedConversation({
    required this.id,
    required this.updatedAt,
    required this.conversation,
    this.stopReason,
  });
  final String id;
  final DateTime updatedAt;
  final AiConversation conversation;
  final String? stopReason;
}

final class AiHistoryRecovery {
  const AiHistoryRecovery(
    this.conversations, {
    this.removedUnreadable = false,
    this.repairedIndex = false,
    this.unsupported = false,
  });
  final List<AiSavedConversation> conversations;
  final bool removedUnreadable;
  final bool repairedIndex;
  final bool unsupported;
}

enum AiHistorySaveResult { saved, storageLimit, evicted, failed, cancelled }

final class _HistoryEntry {
  const _HistoryEntry({
    required this.id,
    required this.updatedAt,
    required this.size,
    this.modifiedAt,
  });

  final String id;
  final DateTime updatedAt;
  final int size;
  final DateTime? modifiedAt;
}

enum AiHistoryCheckpoint {
  conversationRenamed,
  conversationDeleted,
  beforeIndexWrite,
}

/// All file transactions share a queue, including device-wide eviction. Account
/// cleanup uses the same queue so a rename cannot race directory removal.
final class AiHistoryFileStore {
  AiHistoryFileStore({
    Future<Directory> Function()? root,
    DateTime Function()? clock,
    this.checkpoint,
    List<int> Function(File, int)? readFile,
  }) : _root = root ?? (() => aiHistoryStorageRoot()),
       _clock = clock ?? DateTime.now,
       _readFile = readFile;
  static const conversationPlaintextLimit = 512 * 1024;
  static const conversationFileLimit = 640 * 1024;
  static const indexFileLimit = 256 * 1024;
  static const accountByteLimit = 16 * 1024 * 1024;
  static const deviceByteLimit = 64 * 1024 * 1024;
  static const accountConversationLimit = 50;
  final Future<Directory> Function() _root;
  final DateTime Function() _clock;

  /// The coordinator protects accounts whose keys are unavailable or missing.
  bool Function(String accountSegment)? canEvictAccount;
  final List<int> Function(File, int)? _readFile;
  final void Function(AiHistoryCheckpoint, String)? checkpoint;
  Future<void>? _tail;

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final previous = _tail;
    final result = previous == null ? action() : previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tail, tail)) _tail = null;
      }),
    );
    return result;
  }

  Future<Directory> directory(String account) async {
    final root = await _root();
    return Directory(
      '${root.path}/ai_history/${aiHistoryAccountSegment(account)}',
    );
  }

  Future<AiHistoryRecovery> recover(
    String account,
    List<int> key,
    int retentionDays,
  ) => _exclusive(() => _recover(account, key, retentionDays));

  /// Applies retention and capacity from index metadata without loading display
  /// content. Files missing from the index are authenticated once and indexed.
  Future<AiHistoryRecovery> maintain(
    String account,
    List<int> key,
    int retentionDays,
  ) => _exclusive(() async {
    _validateRetention(retentionDays);
    final dir = await _accountDirectory(account);
    if (dir == null) return const AiHistoryRecovery([]);
    final metadata = await _metadataForSave(dir, account, key, retentionDays);
    if (metadata.unsupportedIndex) return metadata.recovery;
    final entries = <String, _HistoryEntry>{
      for (final entry in metadata.entries) entry.id: entry,
    };
    for (final id in _evictAccount(dir, entries.values.toList())) {
      entries.remove(id);
    }
    await _evictDevice();
    entries.removeWhere(
      (id, _) =>
          _entityType('${dir.path}/${_conversationName(id)}') !=
          FileSystemEntityType.file,
    );
    await _writeIndex(dir, account, key, entries.values.toList());
    return metadata.recovery;
  });

  Future<AiHistoryRecovery> _recover(
    String account,
    List<int> key,
    int retentionDays,
  ) async {
    _validateRetention(retentionDays);
    final dir = await _accountDirectory(account);
    if (dir == null) return const AiHistoryRecovery([]);
    var removedUnreadable = false;
    var repairedIndex = false;
    var unsupported = false;
    List<_HistoryEntry>? indexed;
    final index = File('${dir.path}/index.v1.bin');
    if (_entityType(index.path) != FileSystemEntityType.notFound) {
      _requireRegularFile(index);
      try {
        indexed = _decodeIndex(
          await _read(index, key, account, indexFileLimit),
          dir,
        );
      } on AiHistoryUnsupportedFormat {
        unsupported = true;
      } catch (error) {
        if (!_isCorrupt(error)) rethrow;
        repairedIndex = true;
      }
    }

    final values = <AiSavedConversation>[];
    final entries = <String, _HistoryEntry>{
      for (final entry in indexed ?? const <_HistoryEntry>[]) entry.id: entry,
    };
    final seen = <String>{};
    for (final entity in dir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.tmp')) {
        if (_entityType(entity.path) != FileSystemEntityType.file) {
          throw FileSystemException(
            'Invalid history temporary file',
            entity.path,
          );
        }
        if (_clock().difference(File(entity.path).lastModifiedSync()) >
            const Duration(hours: 1)) {
          File(entity.path).deleteSync();
          removedUnreadable = true;
        }
        continue;
      }
      if (!RegExp(r'^c_[0-9a-f]{32}\.v1\.bin$').hasMatch(name)) continue;
      if (_entityType(entity.path) != FileSystemEntityType.file) {
        throw FileSystemException(
          'Invalid history conversation file',
          entity.path,
        );
      }
      final file = File(entity.path);
      final id = name.substring(2, 34);
      seen.add(id);
      AiSavedConversation value;
      try {
        value = _decode(await _read(file, key, account, conversationFileLimit));
        if (_conversationName(value.id) != name) {
          throw const AiHistoryUnsupportedFormat();
        }
      } on AiHistoryUnsupportedFormat {
        unsupported = true;
        continue;
      } catch (error) {
        if (!_isCorrupt(error)) rethrow;
        file.deleteSync();
        entries.remove(id);
        removedUnreadable = true;
        continue;
      }
      if (_expired(value.updatedAt, retentionDays)) {
        _delete(file, value.id);
        entries.remove(value.id);
      } else {
        values.add(value);
        entries[value.id] = _HistoryEntry(
          id: value.id,
          updatedAt: value.updatedAt,
          size: file.lengthSync(),
          modifiedAt: file.lastModifiedSync().toUtc(),
        );
      }
    }
    entries.removeWhere((id, _) => !seen.contains(id));
    values.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final evicted = _evictAccount(dir, entries.values.toList());
    values.removeWhere((value) => evicted.contains(value.id));
    await _evictDevice();
    values.removeWhere(
      (value) =>
          !File('${dir.path}/${_conversationName(value.id)}').existsSync(),
    );
    entries.removeWhere(
      (id, _) =>
          _entityType('${dir.path}/${_conversationName(id)}') !=
          FileSystemEntityType.file,
    );
    if (!unsupported || indexed != null) {
      await _writeIndex(dir, account, key, entries.values.toList());
    }
    return AiHistoryRecovery(
      List.unmodifiable(values),
      removedUnreadable: removedUnreadable,
      repairedIndex: repairedIndex,
      unsupported: unsupported,
    );
  }

  Future<AiHistorySaveResult> save(
    String account,
    List<int> key,
    AiSavedConversation value,
    int retentionDays, {
    bool Function()? isCurrent,
    void Function(AiHistoryRecovery recovery)? onRecovery,
  }) => _exclusive(() async {
    try {
      _conversationName(value.id);
      if (value.stopReason != null && value.stopReason!.length > 128) {
        throw ArgumentError.value(value.stopReason, 'stopReason');
      }
      _validateRetention(retentionDays);
      if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;
      final prepared = await _prepareConversation(value, key, account);
      if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;
      if (prepared == null) return AiHistorySaveResult.storageLimit;

      final dir = await _accountDirectory(account, create: true);
      if (dir == null) {
        throw const FileSystemException('History directory missing');
      }
      final metadata = await _metadataForSave(dir, account, key, retentionDays);
      onRecovery?.call(metadata.recovery);
      if (metadata.unsupportedIndex) return AiHistorySaveResult.failed;
      if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;

      final file = File('${dir.path}/${_conversationName(value.id)}');
      await _atomic(file, prepared);
      checkpoint?.call(AiHistoryCheckpoint.conversationRenamed, value.id);
      final entries = <String, _HistoryEntry>{
        for (final entry in metadata.entries) entry.id: entry,
        value.id: _HistoryEntry(
          id: value.id,
          updatedAt: value.updatedAt,
          size: file.lengthSync(),
          modifiedAt: file.lastModifiedSync().toUtc(),
        ),
      };
      for (final entry in entries.values.toList()) {
        if (_expired(entry.updatedAt, retentionDays)) {
          _delete(File('${dir.path}/${_conversationName(entry.id)}'), entry.id);
          entries.remove(entry.id);
        }
      }
      final evicted = _evictAccount(dir, entries.values.toList());
      for (final id in evicted) {
        entries.remove(id);
      }
      await _evictDevice();
      entries.removeWhere(
        (id, _) =>
            _entityType('${dir.path}/${_conversationName(id)}') !=
            FileSystemEntityType.file,
      );
      await _writeIndex(dir, account, key, entries.values.toList());
      return _entityType(file.path) == FileSystemEntityType.file
          ? AiHistorySaveResult.saved
          : AiHistorySaveResult.evicted;
    } on FileSystemException {
      return AiHistorySaveResult.failed;
    }
  });

  AiSavedConversation _decode(Map<String, Object?> json) {
    if (json.length != 5 || json['version'] != 1) {
      throw const AiHistoryUnsupportedFormat();
    }
    if (json['id'] is! String ||
        json['updatedAt'] is! String ||
        !json.containsKey('stopReason') ||
        !json.containsKey('display') ||
        (json['stopReason'] != null &&
            (json['stopReason'] is! String ||
                (json['stopReason']! as String).length > 128))) {
      throw const AiHistoryUnsupportedFormat();
    }
    final id = json['id']! as String;
    try {
      _conversationName(id);
    } on ArgumentError {
      throw const AiHistoryUnsupportedFormat();
    }
    final date = DateTime.tryParse(json['updatedAt']! as String);
    if (date == null || !date.isUtc) {
      throw const AiHistoryUnsupportedFormat();
    }
    return AiSavedConversation(
      id: id,
      updatedAt: date,
      conversation: aiDisplayFromJson(historyObject(json['display'])),
      stopReason: json['stopReason'] as String?,
    );
  }

  Future<Map<String, Object?>> _read(
    File file,
    List<int> key,
    String account,
    int cap,
  ) async {
    _requireRegularFile(file);
    final length = file.lengthSync();
    if (length > cap || length < 29) {
      throw const _AiHistoryEnvelopeCorrupt();
    }
    final bytes = _readFile == null
        ? await Isolate.run(() => _boundedReadPath(file.path, cap))
        : _readFile(file, cap);
    if (bytes.length > cap) throw const _AiHistoryEnvelopeCorrupt();
    final value = await AiHistoryCipher.decryptJson(
      bytes,
      key,
      account,
      file.uri.pathSegments.last,
      maxPlaintextBytes: cap == conversationFileLimit
          ? conversationPlaintextLimit
          : indexFileLimit,
    );
    return value;
  }

  Future<void> _atomic(File file, List<int> bytes) async {
    final parent = file.parent;
    _requireDirectory(parent);
    final finalType = _entityType(file.path);
    if (finalType != FileSystemEntityType.notFound &&
        finalType != FileSystemEntityType.file) {
      throw FileSystemException('Invalid history destination', file.path);
    }
    final legacyTemp = '${file.path}.tmp';
    if (_entityType(legacyTemp) != FileSystemEntityType.notFound) {
      throw FileSystemException('Unsafe legacy history temp file', legacyTemp);
    }
    await Isolate.run(() => _atomicWrite(file.path, bytes));
    if (_entityType(file.path) != FileSystemEntityType.file) {
      throw FileSystemException('Invalid history destination', file.path);
    }
  }

  Future<void> _writeIndex(
    Directory dir,
    String account,
    List<int> key,
    List<_HistoryEntry> values,
  ) async {
    if (!dir.existsSync()) return;
    checkpoint?.call(AiHistoryCheckpoint.beforeIndexWrite, 'index');
    final bytes = await AiHistoryCipher.encryptJson(
      {
        'version': 1,
        'entries': values
            .map(
              (entry) => {
                'id': entry.id,
                'updatedAt': entry.updatedAt.toUtc().toIso8601String(),
                'size': entry.size,
                'modifiedAt': entry.modifiedAt?.toIso8601String(),
              },
            )
            .toList(),
      },
      key,
      account,
      'index.v1.bin',
    );
    if (bytes.length > indexFileLimit) throw const FormatException();
    await _atomic(File('${dir.path}/index.v1.bin'), bytes);
  }

  void _delete(File file, String id) {
    final type = _entityType(file.path);
    if (type == FileSystemEntityType.file) {
      file.deleteSync();
    } else if (type != FileSystemEntityType.notFound) {
      throw FileSystemException('Invalid history conversation file', file.path);
    }
    checkpoint?.call(AiHistoryCheckpoint.conversationDeleted, id);
  }

  bool _expired(DateTime date, int days) =>
      _clock().toUtc().difference(date) >= Duration(days: days);
  void _validateRetention(int days) {
    if (!const [7, 30, 90].contains(days)) throw ArgumentError.value(days);
  }

  Set<String> _evictAccount(Directory dir, List<_HistoryEntry> values) {
    values.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final removed = <String>{};
    // Reserve the full bounded index envelope, so metadata cannot push a
    // conversation-byte total over the account limit after the next commit.
    var bytes = values.fold<int>(indexFileLimit, (sum, v) => sum + v.size);
    while (values.length > accountConversationLimit ||
        bytes > accountByteLimit) {
      final oldest = values.first;
      bytes -= oldest.size;
      _delete(File('${dir.path}/${_conversationName(oldest.id)}'), oldest.id);
      removed.add(oldest.id);
      values.removeAt(0);
    }
    return removed;
  }

  Future<_SaveMetadata> _metadataForSave(
    Directory dir,
    String account,
    List<int> key,
    int retentionDays,
  ) async {
    var removedUnreadable = false;
    var repairedIndex = false;
    var unsupported = false;
    var unsupportedIndex = false;
    List<_HistoryEntry>? decoded;
    final index = File('${dir.path}/index.v1.bin');
    final indexType = _entityType(index.path);
    if (indexType == FileSystemEntityType.file) {
      try {
        decoded = _decodeIndex(
          await _read(index, key, account, indexFileLimit),
          dir,
        );
      } on AiHistoryUnsupportedFormat {
        unsupported = true;
        unsupportedIndex = true;
      } catch (error) {
        if (!_isCorrupt(error)) rethrow;
        repairedIndex = true;
      }
    } else if (indexType != FileSystemEntityType.notFound) {
      throw FileSystemException('Invalid history index file', index.path);
    }

    if (unsupportedIndex) {
      return _SaveMetadata(
        const [],
        AiHistoryRecovery(const [], unsupported: unsupported),
        unsupportedIndex: true,
      );
    }

    final entries = <String, _HistoryEntry>{
      for (final entry in decoded ?? const <_HistoryEntry>[]) entry.id: entry,
    };
    final seen = <String>{};
    for (final entity in dir.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.tmp')) {
        if (_entityType(entity.path) != FileSystemEntityType.file) {
          throw FileSystemException(
            'Invalid history temporary file',
            entity.path,
          );
        }
        final temp = File(entity.path);
        if (_clock().difference(temp.lastModifiedSync()) >
            const Duration(hours: 1)) {
          temp.deleteSync();
          removedUnreadable = true;
        }
        continue;
      }
      if (!RegExp(r'^c_[0-9a-f]{32}\.v1\.bin$').hasMatch(name)) continue;
      if (_entityType(entity.path) != FileSystemEntityType.file) {
        throw FileSystemException(
          'Invalid history conversation file',
          entity.path,
        );
      }
      final file = File(entity.path);
      final id = name.substring(2, 34);
      seen.add(id);
      final indexed = entries[id];
      if (indexed != null) {
        final actualSize = file.lengthSync();
        final actualModifiedAt = file.lastModifiedSync().toUtc();
        if (actualSize == indexed.size &&
            indexed.modifiedAt != null &&
            actualModifiedAt.isAtSameMomentAs(indexed.modifiedAt!)) {
          continue;
        }
        try {
          final value = _decode(
            await _read(file, key, account, conversationFileLimit),
          );
          if (value.id != id) throw const AiHistoryUnsupportedFormat();
          entries[id] = _HistoryEntry(
            id: id,
            updatedAt: value.updatedAt,
            size: actualSize,
            modifiedAt: actualModifiedAt,
          );
        } on AiHistoryUnsupportedFormat {
          unsupported = true;
        } catch (error) {
          if (!_isCorrupt(error)) rethrow;
          file.deleteSync();
          entries.remove(id);
          removedUnreadable = true;
        }
        continue;
      }
      try {
        final value = _decode(
          await _read(file, key, account, conversationFileLimit),
        );
        if (value.id != id) throw const AiHistoryUnsupportedFormat();
        entries[id] = _HistoryEntry(
          id: id,
          updatedAt: value.updatedAt,
          size: file.lengthSync(),
          modifiedAt: file.lastModifiedSync().toUtc(),
        );
      } on AiHistoryUnsupportedFormat {
        unsupported = true;
      } catch (error) {
        if (!_isCorrupt(error)) rethrow;
        file.deleteSync();
        removedUnreadable = true;
      }
    }
    entries.removeWhere((id, _) => !seen.contains(id));
    for (final entry in entries.values.toList()) {
      if (_expired(entry.updatedAt, retentionDays)) {
        _delete(File('${dir.path}/${_conversationName(entry.id)}'), entry.id);
        entries.remove(entry.id);
      }
    }
    if (repairedIndex) {
      await _writeIndex(dir, account, key, entries.values.toList());
    }
    return _SaveMetadata(
      entries.values.toList(),
      AiHistoryRecovery(
        const [],
        removedUnreadable: removedUnreadable,
        repairedIndex: repairedIndex,
        unsupported: unsupported,
      ),
    );
  }

  Future<void> _evictDevice() async {
    final base = await _baseDirectory();
    if (base == null) return;
    final files = <File>[];
    var indexBytes = 0;
    for (final dir
        in base.listSync(followLinks: false).whereType<Directory>()) {
      if (!RegExp(
        r'^[0-9a-f]{32}$',
      ).hasMatch(dir.uri.pathSegments.where((v) => v.isNotEmpty).last)) {
        continue;
      }
      _requireDirectory(dir);
      final index = File('${dir.path}/index.v1.bin');
      if (_entityType(index.path) == FileSystemEntityType.file) {
        indexBytes += index.lengthSync();
      } else if (_entityType(index.path) != FileSystemEntityType.notFound) {
        throw FileSystemException('Invalid history index file', index.path);
      }
      files.addAll(
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (file) => RegExp(
                r'^c_[0-9a-f]{32}\.v1\.bin$',
              ).hasMatch(file.uri.pathSegments.last),
            ),
      );
    }
    for (final file in files) {
      _requireRegularFile(file);
    }
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    // Existing encrypted indexes plus one bounded replacement are included.
    var bytes = files.fold<int>(
      indexBytes + indexFileLimit,
      (sum, file) => sum + file.lengthSync(),
    );
    for (final file in files) {
      if (bytes <= deviceByteLimit) break;
      final segment = file.parent.uri.pathSegments
          .where((v) => v.isNotEmpty)
          .last;
      if (!(canEvictAccount?.call(segment) ?? true)) continue;
      bytes -= file.lengthSync();
      _delete(file, file.uri.pathSegments.last.substring(2, 34));
      // A foreign account key may be unavailable. Invalidate its encrypted
      // index after deleting the file; the next read rebuilds from survivors.
      final index = File('${file.parent.path}/index.v1.bin');
      if (_entityType(index.path) == FileSystemEntityType.file) {
        bytes -= index.lengthSync();
        index.deleteSync();
      }
    }
  }

  Future<void> deleteAccount(String account) => _exclusive(() async {
    final dir = await _accountDirectory(account);
    if (dir != null) removeAiHistoryDirectory(dir);
  });

  Future<void> deleteOrphans(
    Set<String> accountKeys, {
    bool Function()? isCurrent,
  }) => _exclusive(() async {
    final base = await _baseDirectory();
    if (base == null) return;
    if (!(isCurrent?.call() ?? true)) return;
    final keep = accountKeys.map(aiHistoryAccountSegment).toSet();
    for (final dir
        in base.listSync(followLinks: false).whereType<Directory>()) {
      final name = dir.uri.pathSegments.where((v) => v.isNotEmpty).last;
      if (RegExp(r'^[0-9a-f]{32}$').hasMatch(name) && !keep.contains(name)) {
        _requireDirectory(dir);
        removeAiHistoryDirectory(dir);
      }
    }
  });

  Future<Directory?> _baseDirectory({bool create = false}) async {
    final root = await _root();
    final rootType = _entityType(root.path);
    if (rootType == FileSystemEntityType.notFound) {
      if (!create) return null;
      root.createSync(recursive: true);
    } else if (rootType != FileSystemEntityType.directory) {
      throw FileSystemException('Invalid history storage root', root.path);
    }
    _requireDirectory(root);
    final base = Directory('${root.path}/ai_history');
    final type = _entityType(base.path);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      base.createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Invalid history base directory', base.path);
    }
    _requireDirectory(root);
    _requireDirectory(base);
    return base;
  }

  Future<Directory?> _accountDirectory(
    String account, {
    bool create = false,
  }) async {
    final base = await _baseDirectory(create: create);
    if (base == null) return null;
    final dir = Directory('${base.path}/${aiHistoryAccountSegment(account)}');
    final type = _entityType(dir.path);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      dir.createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Invalid history account directory', dir.path);
    }
    _requireDirectory(base);
    _requireDirectory(dir);
    return dir;
  }

  FileSystemEntityType _entityType(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  void _requireDirectory(Directory directory) {
    if (_entityType(directory.path) != FileSystemEntityType.directory) {
      throw FileSystemException('Invalid history directory', directory.path);
    }
  }

  void _requireRegularFile(File file) {
    if (_entityType(file.path) != FileSystemEntityType.file) {
      throw FileSystemException('Invalid history file', file.path);
    }
  }
}

// This scope contains only sendable arguments. Putting the closure directly in
// save would capture isCurrent and its coordinator/Future context as well.
Future<Uint8List?> _prepareConversation(
  AiSavedConversation value,
  List<int> key,
  String account,
) {
  final snapshot = AiSavedConversation(
    id: value.id,
    updatedAt: value.updatedAt,
    conversation: AiConversation(items: value.conversation.items),
    stopReason: value.stopReason,
  );
  return _runPreparation(snapshot, key, account);
}

Future<Uint8List?> _runPreparation(
  AiSavedConversation value,
  List<int> key,
  String account,
) => Isolate.run(() async {
  final json = <String, Object?>{
    'version': 1,
    'id': value.id,
    'updatedAt': value.updatedAt.toUtc().toIso8601String(),
    'stopReason': value.stopReason,
    'display': aiDisplayJson(value.conversation),
  };
  final items =
      historyObject(json['display'])['items']! as List<Map<String, Object?>>;
  var size = utf8.encode(jsonEncode(json)).length;
  // Oldest tool excerpts degrade first, with their metadata retained.
  for (final item in items) {
    if (size <= AiHistoryFileStore.conversationPlaintextLimit) break;
    if (item['kind'] == 'tool') {
      item['resultExcerpt'] = '';
      item['argsPreview'] = '';
      item['truncated'] = true;
      size = utf8.encode(jsonEncode(json)).length;
    }
  }
  if (size > AiHistoryFileStore.conversationPlaintextLimit) return null;
  return AiHistoryCipher.encryptBytes(
    utf8.encode(jsonEncode(json)),
    key,
    account,
    _conversationName(value.id),
  );
});

final class _AiHistoryEnvelopeCorrupt implements Exception {
  const _AiHistoryEnvelopeCorrupt();
}

final class _SaveMetadata {
  const _SaveMetadata(
    this.entries,
    this.recovery, {
    this.unsupportedIndex = false,
  });

  final List<_HistoryEntry> entries;
  final AiHistoryRecovery recovery;
  final bool unsupportedIndex;
}

bool _isCorrupt(Object error) =>
    error is _AiHistoryEnvelopeCorrupt ||
    error is FormatException ||
    error is SecretBoxAuthenticationError;

List<int> _boundedReadPath(String path, int cap) {
  // Remains bounded even if a file changes between stat and read.
  final handle = File(path).openSync();
  try {
    return handle.readSync(cap + 1);
  } finally {
    handle.closeSync();
  }
}

void _atomicWrite(String path, List<int> bytes) {
  final file = File(path);
  if (_entityTypeStatic(file.parent.path) != FileSystemEntityType.directory) {
    throw FileSystemException('Invalid history directory', file.parent.path);
  }
  final finalType = _entityTypeStatic(path);
  if (finalType != FileSystemEntityType.notFound &&
      finalType != FileSystemEntityType.file) {
    throw FileSystemException('Invalid history destination', path);
  }
  final legacyTemp = '$path.tmp';
  if (_entityTypeStatic(legacyTemp) != FileSystemEntityType.notFound) {
    throw FileSystemException('Unsafe legacy history temp file', legacyTemp);
  }
  final random = Random.secure();
  File? temp;
  for (var attempt = 0; attempt < 8 && temp == null; attempt++) {
    final suffix = List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final candidate = File('$path.$suffix.tmp');
    try {
      candidate.createSync(exclusive: true);
    } on FileSystemException {
      if (_entityTypeStatic(candidate.path) != FileSystemEntityType.notFound) {
        continue;
      }
      rethrow;
    }
    final handle = candidate.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeFromSync(bytes);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    temp = candidate;
  }
  if (temp == null) {
    throw FileSystemException('Unable to create history temp file', path);
  }
  try {
    if (_entityTypeStatic(temp.path) != FileSystemEntityType.file) {
      throw FileSystemException('Invalid history temp file', temp.path);
    }
    temp.renameSync(path);
    if (_entityTypeStatic(path) != FileSystemEntityType.file) {
      throw FileSystemException('Invalid history destination', path);
    }
  } finally {
    if (_entityTypeStatic(temp.path) == FileSystemEntityType.file) {
      temp.deleteSync();
    }
  }
}

List<_HistoryEntry> _decodeIndex(Map<String, Object?> value, Directory dir) {
  if (value.length != 2 ||
      value['version'] != 1 ||
      value['entries'] is! List<Object?>) {
    throw const AiHistoryUnsupportedFormat();
  }
  final ids = <String>{};
  final result = <_HistoryEntry>[];
  for (final raw in value['entries']! as List<Object?>) {
    final entry = historyObject(raw);
    if (!const {2, 3, 4}.contains(entry.length) ||
        entry['id'] is! String ||
        entry['updatedAt'] is! String ||
        (entry.containsKey('size') &&
            (entry['size'] is! int || (entry['size']! as int) < 0)) ||
        (entry.containsKey('modifiedAt') &&
            entry['modifiedAt'] != null &&
            entry['modifiedAt'] is! String) ||
        entry.keys.any(
          (key) =>
              !const {'id', 'updatedAt', 'size', 'modifiedAt'}.contains(key),
        )) {
      throw const AiHistoryUnsupportedFormat();
    }
    final id = entry['id']! as String;
    final date = DateTime.tryParse(entry['updatedAt']! as String);
    final modifiedAt = entry['modifiedAt'] == null
        ? null
        : DateTime.tryParse(entry['modifiedAt']! as String);
    if (!validAiConversationId(id) ||
        !ids.add(id) ||
        date == null ||
        !date.isUtc ||
        (entry['modifiedAt'] != null &&
            (modifiedAt == null || !modifiedAt.isUtc))) {
      throw const AiHistoryUnsupportedFormat();
    }
    final file = File('${dir.path}/${_conversationName(id)}');
    final size = entry['size'] as int?;
    result.add(
      _HistoryEntry(
        id: id,
        updatedAt: date,
        size:
            size ??
            (_entityTypeStatic(file.path) == FileSystemEntityType.file
                ? file.lengthSync()
                : 0),
        modifiedAt: modifiedAt,
      ),
    );
  }
  return result;
}

FileSystemEntityType _entityTypeStatic(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false);
