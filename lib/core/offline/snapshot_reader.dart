import 'dart:convert';
import 'dart:typed_data';

import '../failure.dart';
import '../gitlab_api.dart';
import '../models.dart';
import '../read_cache_disk_contract.dart';
import '../repository_reader.dart';
import 'offline_repository_coordinator.dart';
import 'snapshot_schema.dart';
import 'snapshot_store.dart';

/// Read-only, account-bound view of one completed snapshot. The permit is
/// captured once, so a later account/project revocation invalidates the reader.
final class SnapshotRepositoryReader implements RepositoryReader {
  SnapshotRepositoryReader({required this.owner, required this.coordinator})
    : _permit = coordinator.capture(
        DiskBinding(accountKey: owner.accountKey, generation: owner.generation),
        owner.projectId,
      ) {
    if (owner.snapshotId == null ||
        !validSnapshotId(owner.snapshotId!) ||
        !owner.accountKey.startsWith('${owner.instanceKey}#')) {
      throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
    }
  }
  @override
  final ReaderOwner owner;
  final OfflineRepositoryCoordinator coordinator;
  final SnapshotPermit _permit;

  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    edit: false,
    history: false,
    blame: false,
    refresh: false,
    ai: false,
    webFallback: false,
    share: false,
  );

  Future<T> _read<T>(
    Future<T> Function(
      SnapshotStore store,
      SnapshotRecord record,
      SnapshotTree tree,
    )
    body,
  ) async {
    _permit.check();
    final result = await coordinator.maintain<T>(_permit, (store, index) async {
      _permit.check();
      SnapshotRecord? record;
      for (final item in index?.snapshots ?? const <SnapshotRecord>[]) {
        if (item.id == owner.snapshotId) {
          record = item;
          break;
        }
      }
      if (record == null ||
          record.status != SnapshotStatus.complete ||
          record.projectId != owner.projectId ||
          record.sha != owner.sha ||
          record.subPath != owner.subPath) {
        throw const SnapshotOperationException(SnapshotFailure.storageError);
      }
      final tree = await store.readTree(record);
      _permit.check();
      if (tree == null) {
        throw const SnapshotOperationException(SnapshotFailure.storageError);
      }
      final result = await body(store, record, tree);
      _permit.check();
      return result;
    }, allowReadOnly: true);
    _permit.check();
    if (result == null) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
    return result;
  }

  bool _inside(String path, {bool root = false}) {
    if (root && (path.isEmpty || path == owner.subPath)) return true;
    return validSnapshotPath(path) &&
        (owner.subPath.isEmpty || path.startsWith('${owner.subPath}/'));
  }

  @override
  Future<ApiPage<Json>> tree(String path, {Uri? next}) async {
    if (next != null || !_inside(path, root: true)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final directory = path.isEmpty ? owner.subPath : path;
    return _read((store, record, tree) async {
      if (directory.isNotEmpty &&
          directory != owner.subPath &&
          !tree.entries.any(
            (e) => e.path == directory && e.type == SnapshotEntryType.tree,
          )) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final prefix = directory.isEmpty ? '' : '$directory/';
      final rows = <Json>[];
      for (final entry in tree.entries) {
        if (!entry.path.startsWith(prefix)) continue;
        final rest = entry.path.substring(prefix.length);
        if (rest.isEmpty || rest.contains('/')) continue;
        rows.add(<String, dynamic>{
          'id': entry.id,
          'name': rest,
          'path': entry.path,
          'type': entry.type.name,
          'mode': entry.mode,
        });
      }
      return ApiPage<Json>(List<Json>.unmodifiable(rows));
    });
  }

  void checkCurrent() => _permit.check();

  /// A typed hint for the presentation layer; no raw-file fallback is allowed.
  Future<bool> hasAttributeOmissions() => _read((store, record, tree) async {
    if ((record.notSaved[SnapshotEntryState.missing] ?? 0) +
            (record.notSaved[SnapshotEntryState.mismatch] ?? 0) ==
        0) {
      return false;
    }
    final path = owner.subPath.isEmpty
        ? '.gitattributes'
        : '${owner.subPath}/.gitattributes';
    SnapshotTreeEntry? attributes;
    for (final entry in tree.entries) {
      if (entry.path == path) attributes = entry;
    }
    if (attributes == null ||
        attributes.state != SnapshotEntryState.saved ||
        attributes.kind != SnapshotContentKind.text) {
      return false;
    }
    final bytes = await store.readBlob(record.objectFormat, attributes.id);
    _permit.check();
    if (bytes == null || bytes.length != attributes.size) return false;
    try {
      return RegExp(
        r'\b(export-ignore|export-subst|ident|eol|text|working-tree-encoding|filter)\b',
      ).hasMatch(utf8.decode(bytes));
    } on FormatException {
      return false;
    }
  });

  Future<SnapshotTreeEntry?> snapshotEntry(String path) async {
    final entries = await _read((store, record, tree) async {
      if (!_inside(path)) throw const ApiFailure(FailureKind.unsupported);
      return tree.entries.where((entry) => entry.path == path).toList();
    });
    _permit.check();
    return entries.isEmpty ? null : entries.single;
  }

  @override
  Future<RepositoryEntryState> entryState(String path) async {
    final entry = await snapshotEntry(path);
    _permit.check();
    if (entry == null) return RepositoryEntryState.missing;
    if (entry.state == SnapshotEntryState.saved) {
      return RepositoryEntryState.available;
    }
    return RepositoryEntryState.values.byName(entry.state.name);
  }

  Future<Uint8List> _readBytes(
    String path,
    int maxBytes, {
    bool textOnly = false,
  }) => _read((store, record, tree) async {
    if (!_inside(path) || maxBytes < 0) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    SnapshotTreeEntry? entry;
    for (final item in tree.entries) {
      if (item.path == path) {
        entry = item;
        break;
      }
    }
    if (entry == null ||
        entry.type != SnapshotEntryType.blob ||
        entry.state != SnapshotEntryState.saved ||
        (textOnly &&
            entry.kind != SnapshotContentKind.text &&
            entry.kind != SnapshotContentKind.lfsPointer)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    if (entry.size == null || entry.size! > maxBytes) {
      throw const ApiFailure(FailureKind.tooLarge);
    }
    final bytes = await store.readBlob(record.objectFormat, entry.id);
    _permit.check();
    if (bytes == null || bytes.length != entry.size) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
    return bytes;
  });

  @override
  Future<Uint8List> bytes(String path, {int maxBytes = 10 * 1024 * 1024}) =>
      _readBytes(path, maxBytes);

  @override
  Future<String> text(String path) async {
    final data = await _readBytes(path, 2 * 1024 * 1024, textOnly: true);
    _permit.check();
    try {
      final text = utf8.decode(data);
      _permit.check();
      return text;
    } on FormatException {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
  }
}
