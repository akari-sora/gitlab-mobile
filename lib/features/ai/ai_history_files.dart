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
  const AiHistoryRecovery(this.conversations, {this.removedUnreadable = false});
  final List<AiSavedConversation> conversations;
  final bool removedUnreadable;
}

enum AiHistorySaveResult { saved, storageLimit, cancelled }

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
       _readFile = readFile ?? _boundedRead;
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
  final List<int> Function(File, int) _readFile;
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

  Future<AiHistoryRecovery> _recover(
    String account,
    List<int> key,
    int retentionDays,
  ) async {
    _validateRetention(retentionDays);
    final dir = await directory(account);
    if (!dir.existsSync()) return const AiHistoryRecovery([]);
    // Never traverse symlinks planted in a restored or externally edited tree.
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('Invalid history directory');
    }
    var damaged = false;
    final index = File('${dir.path}/index.v1.bin');
    if (index.existsSync()) {
      try {
        final value = await _read(index, key, account, indexFileLimit);
        _validateIndex(value);
      } catch (error) {
        if (!_isCorrupt(error)) rethrow;
        // Conversation files are the recovery source of truth, including a
        // crash after their rename and before the index write.
        damaged = true;
      }
    }
    final values = <AiSavedConversation>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.tmp')) {
        if (_clock().difference(entity.lastModifiedSync()) >
            const Duration(hours: 1)) {
          entity.deleteSync();
        }
        continue;
      }
      if (!RegExp(r'^c_[0-9a-f]{32}\.v1\.bin$').hasMatch(name)) continue;
      AiSavedConversation value;
      try {
        value = _decode(
          await _read(entity, key, account, conversationFileLimit),
        );
        if (_conversationName(value.id) != name) throw const FormatException();
      } catch (error) {
        if (!_isCorrupt(error)) rethrow;
        entity.deleteSync();
        damaged = true;
        continue;
      }
      if (_expired(value.updatedAt, retentionDays)) {
        _delete(entity, value.id);
      } else {
        values.add(value);
      }
    }
    values.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    _evictAccount(dir, values);
    await _evictDevice();
    values.removeWhere(
      (value) =>
          !File('${dir.path}/${_conversationName(value.id)}').existsSync(),
    );
    await _writeIndex(dir, account, key, values);
    return AiHistoryRecovery(
      List.unmodifiable(values),
      removedUnreadable: damaged,
    );
  }

  Future<AiHistorySaveResult> save(
    String account,
    List<int> key,
    AiSavedConversation value,
    int retentionDays, {
    bool Function()? isCurrent,
  }) => _exclusive(() async {
    _conversationName(value.id);
    if (value.stopReason != null && value.stopReason!.length > 128) {
      throw ArgumentError.value(value.stopReason, 'stopReason');
    }
    _validateRetention(retentionDays);
    if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;
    final prepared = await _prepareConversation(value, key, account);
    if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;
    if (prepared == null) return AiHistorySaveResult.storageLimit;
    final recovered = await _recover(account, key, retentionDays);
    if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;
    final dir = await directory(account);
    dir.createSync(recursive: true);
    if (!(isCurrent?.call() ?? true)) return AiHistorySaveResult.cancelled;
    _atomic(File('${dir.path}/${_conversationName(value.id)}'), prepared);
    checkpoint?.call(AiHistoryCheckpoint.conversationRenamed, value.id);
    final values = [
      ...recovered.conversations.where((item) => item.id != value.id),
      value,
    ]..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    // Retention also applies to an explicitly saved old timestamp.
    for (final item in values.toList()) {
      if (_expired(item.updatedAt, retentionDays)) {
        _delete(File('${dir.path}/${_conversationName(item.id)}'), item.id);
        values.remove(item);
      }
    }
    _evictAccount(dir, values);
    await _evictDevice();
    values.removeWhere(
      (item) => !File('${dir.path}/${_conversationName(item.id)}').existsSync(),
    );
    await _writeIndex(dir, account, key, values);
    return File('${dir.path}/${_conversationName(value.id)}').existsSync()
        ? AiHistorySaveResult.saved
        : AiHistorySaveResult.storageLimit;
  });

  AiSavedConversation _decode(Map<String, Object?> json) {
    if (json['version'] != 1 ||
        json['id'] is! String ||
        json['updatedAt'] is! String ||
        (json['stopReason'] != null &&
            (json['stopReason'] is! String ||
                (json['stopReason']! as String).length > 128))) {
      throw const FormatException();
    }
    final id = json['id']! as String;
    _conversationName(id);
    final date = DateTime.parse(json['updatedAt']! as String);
    if (!date.isUtc) throw const FormatException();
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
    final length = file.lengthSync();
    if (length > cap || length < 29) throw const FormatException();
    final bytes = _readFile(file, cap);
    if (bytes.length > cap) throw const FormatException();
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

  void _atomic(File file, List<int> bytes) {
    final temp = File('${file.path}.tmp');
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(file.path);
  }

  Future<void> _writeIndex(
    Directory dir,
    String account,
    List<int> key,
    List<AiSavedConversation> values,
  ) async {
    if (!dir.existsSync()) return;
    checkpoint?.call(AiHistoryCheckpoint.beforeIndexWrite, 'index');
    final bytes = await AiHistoryCipher.encryptJson(
      {
        'version': 1,
        'entries': values
            .map(
              (v) => {
                'id': v.id,
                'updatedAt': v.updatedAt.toUtc().toIso8601String(),
              },
            )
            .toList(),
      },
      key,
      account,
      'index.v1.bin',
    );
    if (bytes.length > indexFileLimit) throw const FormatException();
    _atomic(File('${dir.path}/index.v1.bin'), bytes);
  }

  void _delete(File file, String id) {
    if (file.existsSync()) file.deleteSync();
    checkpoint?.call(AiHistoryCheckpoint.conversationDeleted, id);
  }

  bool _expired(DateTime date, int days) =>
      _clock().toUtc().difference(date) >= Duration(days: days);
  void _validateRetention(int days) {
    if (!const [7, 30, 90].contains(days)) throw ArgumentError.value(days);
  }

  void _evictAccount(Directory dir, List<AiSavedConversation> values) {
    int size(AiSavedConversation v) =>
        File('${dir.path}/${_conversationName(v.id)}').lengthSync();
    // Reserve the full bounded index envelope, so metadata cannot push a
    // conversation-byte total over the account limit after the next commit.
    var bytes = values.fold<int>(indexFileLimit, (sum, v) => sum + size(v));
    while (values.length > accountConversationLimit ||
        bytes > accountByteLimit) {
      final oldest = values.first;
      bytes -= size(oldest);
      _delete(File('${dir.path}/${_conversationName(oldest.id)}'), oldest.id);
      values.removeAt(0);
    }
  }

  Future<void> _evictDevice() async {
    final root = await _root();
    final base = Directory('${root.path}/ai_history');
    if (!base.existsSync()) return;
    final files = <File>[];
    var indexBytes = 0;
    for (final dir
        in base.listSync(followLinks: false).whereType<Directory>()) {
      if (!RegExp(
        r'^[0-9a-f]{32}$',
      ).hasMatch(dir.uri.pathSegments.where((v) => v.isNotEmpty).last)) {
        continue;
      }
      final index = File('${dir.path}/index.v1.bin');
      if (index.existsSync()) indexBytes += index.lengthSync();
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
      if (index.existsSync()) {
        bytes -= index.lengthSync();
        index.deleteSync();
      }
    }
  }

  Future<void> deleteAccount(String account) => _exclusive(() async {
    final dir = await directory(account);
    if (dir.existsSync()) removeAiHistoryDirectory(dir);
  });

  Future<void> deleteOrphans(
    Set<String> accountKeys, {
    bool Function()? isCurrent,
  }) => _exclusive(() async {
    final root = await _root();
    final base = Directory('${root.path}/ai_history');
    if (!base.existsSync()) return;
    if (!(isCurrent?.call() ?? true)) return;
    final keep = accountKeys.map(aiHistoryAccountSegment).toSet();
    for (final dir
        in base.listSync(followLinks: false).whereType<Directory>()) {
      final name = dir.uri.pathSegments.where((v) => v.isNotEmpty).last;
      if (RegExp(r'^[0-9a-f]{32}$').hasMatch(name) && !keep.contains(name)) {
        removeAiHistoryDirectory(dir);
      }
    }
  });
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

bool _isCorrupt(Object error) =>
    error is FormatException ||
    error is SecretBoxAuthenticationError ||
    error is ArgumentError;

List<int> _boundedRead(File file, int cap) {
  // Remains bounded even if a file changes between stat and read.
  final handle = file.openSync();
  try {
    return handle.readSync(cap + 1);
  } finally {
    handle.closeSync();
  }
}

void _validateIndex(Map<String, Object?> value) {
  if (value.length != 2 ||
      value['version'] != 1 ||
      value['entries'] is! List<Object?>) {
    throw const FormatException();
  }
  final ids = <String>{};
  for (final raw in value['entries']! as List<Object?>) {
    final entry = historyObject(raw);
    if (entry.length != 2 ||
        entry['id'] is! String ||
        entry['updatedAt'] is! String) {
      throw const FormatException();
    }
    final id = entry['id']! as String;
    final date = DateTime.tryParse(entry['updatedAt']! as String);
    if (!validAiConversationId(id) ||
        !ids.add(id) ||
        date == null ||
        !date.isUtc) {
      throw const FormatException();
    }
  }
}
