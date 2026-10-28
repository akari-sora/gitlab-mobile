import 'dart:convert';
import 'dart:typed_data';

const snapshotIndexLimit = 1024 * 1024;
const snapshotTreeLimit = 4 * 1024 * 1024;
const snapshotBlobLimit = 10 * 1024 * 1024;
const snapshotAccountLimit = 600 * 1024 * 1024;
const snapshotStoredLimit = 150 * 1024 * 1024;
const snapshotEntryLimit = 5000;
const snapshotCountLimit = 30;
const snapshotEnvelopeOverhead = 29;

enum SnapshotObjectFormat { sha1, sha256 }

enum SnapshotRefKind { branch, tag }

enum SnapshotStatus { saving, paused, failed, complete, superseded }

enum SnapshotProbe { ok, refGone, commitGone }

enum SnapshotEntryType { blob, tree, commit }

enum SnapshotEntryState {
  pending,
  saved,
  tooLarge,
  binary,
  missing,
  mismatch,
  symlink,
  submodule,
  unsupportedType,
}

enum SnapshotContentKind { text, image, lfsPointer }

enum SnapshotFailure {
  tooManyEntries,
  treeTooLarge,
  indexTooLarge,
  archiveTooLarge,
  storageFull,
  deviceFull,
  storageError,
  keyUnavailable,
  offlineCacheDisabled,
  invalidTree,
  corruptArchive,
  shaMismatch,
  resolveFailed,
  serverForbidsStorage,
  accessLost,
  versionGone,
  rateLimited,
  network,
  sessionEnded,
}

enum SnapshotSchemaError { malformed, newerSchema, tooLarge, bindingMismatch }

/// Errors never include account identifiers, repository paths or content.
final class SnapshotSchemaException implements Exception {
  const SnapshotSchemaException(this.code);
  final SnapshotSchemaError code;
  @override
  String toString() => 'SnapshotSchemaException(${code.name})';
}

final _idPattern = RegExp(r'^[a-f0-9]{32}$');
final _sha1Pattern = RegExp(r'^[a-f0-9]{40}$');
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

bool validSnapshotId(String id) => _idPattern.hasMatch(id);
bool validObjectId(String id, SnapshotObjectFormat format) =>
    (format == SnapshotObjectFormat.sha1 ? _sha1Pattern : _sha256Pattern)
        .hasMatch(id);

bool validSnapshotPath(String path, {bool allowEmpty = false}) {
  if (allowEmpty && path.isEmpty) return true;
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\u0000') ||
      utf8.encode(path).length > 4096 ||
      utf8.decode(utf8.encode(path)) != path) {
    return false;
  }
  return path
      .split('/')
      .every((part) => part.isNotEmpty && part != '.' && part != '..');
}

final class SnapshotTreeEntry {
  const SnapshotTreeEntry({
    required this.path,
    required this.type,
    required this.mode,
    required this.id,
    required this.state,
    this.kind,
    this.size,
    this.lines,
  });
  final String path;
  final SnapshotEntryType type;
  final String mode;
  final String id;
  final SnapshotEntryState state;
  final SnapshotContentKind? kind;
  final int? size;
  final int? lines;

  SnapshotTreeEntry copyWith({
    SnapshotEntryState? state,
    SnapshotContentKind? kind,
    int? size,
    int? lines,
  }) => SnapshotTreeEntry(
    path: path,
    type: type,
    mode: mode,
    id: id,
    state: state ?? this.state,
    kind: kind ?? this.kind,
    size: size ?? this.size,
    lines: lines ?? this.lines,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'p': path,
    't': type.name,
    'm': mode,
    'i': id,
    's': state.name,
    if (kind != null) 'k': kind!.name,
    if (size != null) 'z': size,
    if (lines != null) 'l': lines,
  };

  static SnapshotTreeEntry fromJson(Object? raw) {
    final v = _object(raw);
    _keys(v, const {'p', 't', 'm', 'i', 's'}, const {'k', 'z', 'l'});
    return SnapshotTreeEntry(
      path: _string(v['p']),
      type: _enum(SnapshotEntryType.values, v['t']),
      mode: _string(v['m']),
      id: _string(v['i']),
      state: _enum(SnapshotEntryState.values, v['s']),
      kind: v.containsKey('k')
          ? _enum(SnapshotContentKind.values, v['k'])
          : null,
      size: v.containsKey('z') ? _nonnegative(v['z']) : null,
      lines: v.containsKey('l') ? _nonnegative(v['l']) : null,
    );
  }
}

final class SnapshotTree {
  SnapshotTree({
    required this.snapshotId,
    required this.sha,
    required this.subPath,
    required List<SnapshotTreeEntry> entries,
  }) : entries = List.unmodifiable(entries);
  final String snapshotId, sha, subPath;
  final List<SnapshotTreeEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'snapshotId': snapshotId,
    'sha': sha,
    'subPath': subPath,
    'e': entries.map((entry) => entry.toJson()).toList(),
  };

  Uint8List encode({
    required SnapshotObjectFormat format,
    bool complete = false,
  }) {
    validate(format: format, complete: complete);
    final encoded = Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
    if (encoded.length > snapshotTreeLimit) {
      throw const SnapshotSchemaException(SnapshotSchemaError.tooLarge);
    }
    return encoded;
  }

  int get reservedBytes {
    final json = toJson();
    json['e'] = [
      for (final entry in entries)
        <String, Object?>{
          ...entry.toJson(),
          's': 'unsupportedType',
          'k': 'lfsPointer',
          'z': 9999999999,
          'l': 99999,
        },
    ];
    return utf8.encode(jsonEncode(json)).length;
  }

  void validate({required SnapshotObjectFormat format, bool complete = false}) {
    if (!validSnapshotId(snapshotId) ||
        !validObjectId(sha, format) ||
        !validSnapshotPath(subPath, allowEmpty: true) ||
        entries.length > snapshotEntryLimit) {
      throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
    }
    final paths = <String, SnapshotTreeEntry>{};
    var savedBytes = 0;
    for (final entry in entries) {
      final validMode = switch (entry.type) {
        SnapshotEntryType.blob => const {
          '100644',
          '100755',
          '120000',
        }.contains(entry.mode),
        SnapshotEntryType.tree => entry.mode == '040000',
        SnapshotEntryType.commit => entry.mode == '160000',
      };
      if (!validSnapshotPath(entry.path) ||
          (subPath.isNotEmpty && !entry.path.startsWith('$subPath/')) ||
          !validObjectId(entry.id, format) ||
          !validMode ||
          paths.containsKey(entry.path) ||
          (complete && entry.state == SnapshotEntryState.pending) ||
          (entry.state == SnapshotEntryState.saved &&
              (entry.type == SnapshotEntryType.commit ||
                  (entry.type == SnapshotEntryType.blob &&
                      (entry.kind == null || entry.size == null)) ||
                  (entry.type == SnapshotEntryType.tree &&
                      (entry.kind != null || entry.size != null)))) ||
          (entry.kind != null && entry.state != SnapshotEntryState.saved) ||
          (entry.size != null &&
              (entry.size! < 0 || entry.size! > snapshotBlobLimit)) ||
          (entry.lines != null && (entry.lines! < 0 || entry.lines! > 20000))) {
        throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
      }
      if (entry.type == SnapshotEntryType.blob &&
          entry.state == SnapshotEntryState.saved) {
        savedBytes += entry.size!;
        if (savedBytes > snapshotStoredLimit) {
          throw const SnapshotSchemaException(SnapshotSchemaError.tooLarge);
        }
      }
      paths[entry.path] = entry;
    }
    for (final entry in entries) {
      final slash = entry.path.lastIndexOf('/');
      if (slash < 0) continue;
      final parent = entry.path.substring(0, slash);
      if (parent == subPath) continue;
      if (paths[parent]?.type != SnapshotEntryType.tree) {
        throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
      }
    }
    if (reservedBytes > snapshotTreeLimit) {
      throw const SnapshotSchemaException(SnapshotSchemaError.tooLarge);
    }
  }

  static SnapshotTree decode(
    List<int> bytes, {
    required SnapshotObjectFormat format,
    required String snapshotId,
    required String sha,
    required String subPath,
    bool complete = false,
  }) {
    if (bytes.length > snapshotTreeLimit) {
      throw const SnapshotSchemaException(SnapshotSchemaError.tooLarge);
    }
    try {
      final v = _object(jsonDecode(utf8.decode(bytes)));
      _version(v);
      _keys(v, const {'schema', 'snapshotId', 'sha', 'subPath', 'e'});
      final tree = SnapshotTree(
        snapshotId: _string(v['snapshotId']),
        sha: _string(v['sha']),
        subPath: _string(v['subPath']),
        entries: [
          for (final e in _array(v['e'])) SnapshotTreeEntry.fromJson(e),
        ],
      );
      if (tree.snapshotId != snapshotId ||
          tree.sha != sha ||
          tree.subPath != subPath) {
        throw const SnapshotSchemaException(
          SnapshotSchemaError.bindingMismatch,
        );
      }
      tree.validate(format: format, complete: complete);
      return tree;
    } on SnapshotSchemaException {
      rethrow;
    } catch (_) {
      throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
    }
  }
}

final class SnapshotRecord {
  SnapshotRecord({
    required this.id,
    required this.projectId,
    required this.projectPath,
    required this.projectName,
    required this.defaultBranch,
    required this.refKind,
    required this.refName,
    required this.sha,
    required this.objectFormat,
    required this.subPath,
    required this.commitTitle,
    required this.committedAt,
    required this.status,
    required this.createdAt,
    this.failure,
    this.interrupted = false,
    this.replaces,
    this.savedAt,
    this.entryCount = 0,
    this.savedCount = 0,
    Map<SnapshotEntryState, int> notSaved = const {},
    this.storedBytes = 0,
    this.headSha,
    this.probe,
    this.probedAt,
  }) : notSaved = Map.unmodifiable(notSaved);
  final String id,
      projectPath,
      projectName,
      defaultBranch,
      refName,
      sha,
      subPath,
      commitTitle;
  final int projectId;
  final SnapshotRefKind refKind;
  final SnapshotObjectFormat objectFormat;
  final DateTime committedAt, createdAt;
  final SnapshotStatus status;
  final SnapshotFailure? failure;
  final bool interrupted;
  final String? replaces;
  final DateTime? savedAt;
  final int entryCount, savedCount, storedBytes;
  final Map<SnapshotEntryState, int> notSaved;
  final String? headSha;
  final SnapshotProbe? probe;
  final DateTime? probedAt;

  SnapshotRecord copyWith({
    SnapshotStatus? status,
    SnapshotFailure? failure,
    bool clearFailure = false,
    bool? interrupted,
    DateTime? savedAt,
    int? entryCount,
    int? savedCount,
    Map<SnapshotEntryState, int>? notSaved,
    int? storedBytes,
    String? headSha,
    SnapshotProbe? probe,
    DateTime? probedAt,
  }) => SnapshotRecord(
    id: id,
    projectId: projectId,
    projectPath: projectPath,
    projectName: projectName,
    defaultBranch: defaultBranch,
    refKind: refKind,
    refName: refName,
    sha: sha,
    objectFormat: objectFormat,
    subPath: subPath,
    commitTitle: commitTitle,
    committedAt: committedAt,
    status: status ?? this.status,
    createdAt: createdAt,
    failure: clearFailure ? null : (failure ?? this.failure),
    interrupted: interrupted ?? this.interrupted,
    replaces: replaces,
    savedAt: savedAt ?? this.savedAt,
    entryCount: entryCount ?? this.entryCount,
    savedCount: savedCount ?? this.savedCount,
    notSaved: notSaved ?? this.notSaved,
    storedBytes: storedBytes ?? this.storedBytes,
    headSha: headSha ?? this.headSha,
    probe: probe ?? this.probe,
    probedAt: probedAt ?? this.probedAt,
  );

  static const missingStates = <SnapshotEntryState>{
    SnapshotEntryState.tooLarge,
    SnapshotEntryState.binary,
    SnapshotEntryState.missing,
    SnapshotEntryState.mismatch,
    SnapshotEntryState.symlink,
    SnapshotEntryState.submodule,
    SnapshotEntryState.unsupportedType,
  };
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'projectId': projectId,
    'projectPath': projectPath,
    'projectName': projectName,
    'defaultBranch': defaultBranch,
    'refKind': refKind.name,
    'refName': refName,
    'sha': sha,
    'objectFormat': objectFormat.name,
    'subPath': subPath,
    'commitTitle': commitTitle,
    'committedAt': _dateText(committedAt),
    'status': status.name,
    'failure': failure?.name,
    'interrupted': interrupted,
    'replaces': replaces,
    'createdAt': _dateText(createdAt),
    'savedAt': savedAt == null ? null : _dateText(savedAt!),
    'entryCount': entryCount,
    'savedCount': savedCount,
    'notSaved': <String, int>{
      for (final state in missingStates) state.name: notSaved[state] ?? 0,
    },
    'storedBytes': storedBytes,
    'headSha': headSha,
    'probe': probe?.name,
    'probedAt': probedAt == null ? null : _dateText(probedAt!),
  };

  void validate() {
    if (!validSnapshotId(id) ||
        projectId <= 0 ||
        projectName.runes.length > 255 ||
        utf8.encode(projectPath).length > 1024 ||
        utf8.encode(refName).length > 1024 ||
        !validSnapshotPath(subPath, allowEmpty: true) ||
        commitTitle.runes.length > 200 ||
        !validObjectId(sha, objectFormat) ||
        (headSha != null && !validObjectId(headSha!, objectFormat)) ||
        (replaces != null && (!validSnapshotId(replaces!) || replaces == id)) ||
        entryCount < 0 ||
        entryCount > snapshotEntryLimit ||
        savedCount < 0 ||
        savedCount > entryCount ||
        storedBytes < 0 ||
        storedBytes > snapshotStoredLimit ||
        notSaved.keys.any((e) => !missingStates.contains(e)) ||
        notSaved.values.any((n) => n < 0) ||
        (status == SnapshotStatus.complete && savedAt == null)) {
      throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
    }
  }

  static SnapshotRecord fromJson(Object? raw) {
    final v = _object(raw);
    _keys(v, const {
      'id',
      'projectId',
      'projectPath',
      'projectName',
      'defaultBranch',
      'refKind',
      'refName',
      'sha',
      'objectFormat',
      'subPath',
      'commitTitle',
      'committedAt',
      'status',
      'failure',
      'interrupted',
      'replaces',
      'createdAt',
      'savedAt',
      'entryCount',
      'savedCount',
      'notSaved',
      'storedBytes',
      'headSha',
      'probe',
      'probedAt',
    });
    final missing = _object(v['notSaved']);
    _keys(missing, {for (final s in missingStates) s.name});
    final item = SnapshotRecord(
      id: _string(v['id']),
      projectId: _nonnegative(v['projectId']),
      projectPath: _string(v['projectPath']),
      projectName: _string(v['projectName']),
      defaultBranch: _string(v['defaultBranch']),
      refKind: _enum(SnapshotRefKind.values, v['refKind']),
      refName: _string(v['refName']),
      sha: _string(v['sha']),
      objectFormat: _enum(SnapshotObjectFormat.values, v['objectFormat']),
      subPath: _string(v['subPath']),
      commitTitle: _string(v['commitTitle']),
      committedAt: _date(v['committedAt']),
      status: _enum(SnapshotStatus.values, v['status']),
      failure: v['failure'] == null
          ? null
          : _enum(SnapshotFailure.values, v['failure']),
      interrupted: _bool(v['interrupted']),
      replaces: _nullableString(v['replaces']),
      createdAt: _date(v['createdAt']),
      savedAt: _nullableDate(v['savedAt']),
      entryCount: _nonnegative(v['entryCount']),
      savedCount: _nonnegative(v['savedCount']),
      notSaved: {
        for (final s in missingStates) s: _nonnegative(missing[s.name]),
      },
      storedBytes: _nonnegative(v['storedBytes']),
      headSha: _nullableString(v['headSha']),
      probe: v['probe'] == null
          ? null
          : _enum(SnapshotProbe.values, v['probe']),
      probedAt: _nullableDate(v['probedAt']),
    );
    item.validate();
    return item;
  }
}

final class SnapshotRemovedNotice {
  const SnapshotRemovedNotice(this.count, this.at);
  final int count;
  final DateTime at;
}

final class SnapshotIndex {
  SnapshotIndex({
    required this.accountKey,
    required this.lastValidatedAt,
    required this.consentAt,
    required List<SnapshotRecord> snapshots,
    this.lastProbeAt,
    this.gcPending = false,
    this.removedNotice,
  }) : snapshots = List.unmodifiable(snapshots);
  final String accountKey;
  final DateTime lastValidatedAt, consentAt;
  final DateTime? lastProbeAt;
  final bool gcPending;
  final SnapshotRemovedNotice? removedNotice;
  final List<SnapshotRecord> snapshots;

  SnapshotIndex copyWith({
    DateTime? lastValidatedAt,
    DateTime? lastProbeAt,
    bool? gcPending,
    SnapshotRemovedNotice? removedNotice,
    List<SnapshotRecord>? snapshots,
  }) => SnapshotIndex(
    accountKey: accountKey,
    lastValidatedAt: lastValidatedAt ?? this.lastValidatedAt,
    consentAt: consentAt,
    snapshots: snapshots ?? this.snapshots,
    lastProbeAt: lastProbeAt ?? this.lastProbeAt,
    gcPending: gcPending ?? this.gcPending,
    removedNotice: removedNotice ?? this.removedNotice,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'account': accountKey,
    'lastValidatedAt': _dateText(lastValidatedAt),
    'lastProbeAt': lastProbeAt == null ? null : _dateText(lastProbeAt!),
    'consentAt': _dateText(consentAt),
    'gcPending': gcPending,
    'removedNotice': removedNotice == null
        ? null
        : <String, Object?>{
            'count': removedNotice!.count,
            'at': _dateText(removedNotice!.at),
          },
    'snapshots': snapshots.map((s) => s.toJson()).toList(),
  };

  Uint8List encode() {
    _validate();
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
    if (bytes.length > snapshotIndexLimit) {
      throw const SnapshotSchemaException(SnapshotSchemaError.tooLarge);
    }
    return bytes;
  }

  void _validate() {
    final ids = <String>{};
    if (accountKey.isEmpty ||
        (removedNotice != null && removedNotice!.count <= 0)) {
      throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
    }
    for (final snapshot in snapshots) {
      snapshot.validate();
      if (!ids.add(snapshot.id)) {
        throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
      }
    }
  }

  static SnapshotIndex decode(List<int> bytes, {required String accountKey}) {
    if (bytes.length > snapshotIndexLimit) {
      throw const SnapshotSchemaException(SnapshotSchemaError.tooLarge);
    }
    try {
      final v = _object(jsonDecode(utf8.decode(bytes)));
      _version(v);
      _keys(v, const {
        'schema',
        'account',
        'lastValidatedAt',
        'lastProbeAt',
        'consentAt',
        'gcPending',
        'removedNotice',
        'snapshots',
      });
      if (v['account'] != accountKey) {
        throw const SnapshotSchemaException(
          SnapshotSchemaError.bindingMismatch,
        );
      }
      SnapshotRemovedNotice? notice;
      if (v['removedNotice'] != null) {
        final n = _object(v['removedNotice']);
        _keys(n, const {'count', 'at'});
        notice = SnapshotRemovedNotice(
          _nonnegative(n['count']),
          _date(n['at']),
        );
      }
      final index = SnapshotIndex(
        accountKey: accountKey,
        lastValidatedAt: _date(v['lastValidatedAt']),
        lastProbeAt: _nullableDate(v['lastProbeAt']),
        consentAt: _date(v['consentAt']),
        gcPending: _bool(v['gcPending']),
        removedNotice: notice,
        snapshots: [
          for (final item in _array(v['snapshots']))
            SnapshotRecord.fromJson(item),
        ],
      );
      index._validate();
      return index;
    } on SnapshotSchemaException {
      rethrow;
    } catch (_) {
      throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
    }
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
  return value;
}

List<Object?> _array(Object? value) {
  if (value is! List<Object?>) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
  return value;
}

void _keys(
  Map<String, Object?> value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (!value.keys.toSet().containsAll(required) ||
      value.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
}

void _version(Map<String, Object?> value) {
  final version = value['schema'];
  if (version is int && version > 1) {
    throw const SnapshotSchemaException(SnapshotSchemaError.newerSchema);
  }
  if (version != 1) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
}

String _string(Object? value) {
  if (value is! String) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
  return value;
}

String? _nullableString(Object? value) => value == null ? null : _string(value);
bool _bool(Object? value) {
  if (value is! bool) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
  return value;
}

int _nonnegative(Object? value) {
  if (value is! int || value < 0) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
  return value;
}

String _dateText(DateTime value) => value.toUtc().toIso8601String();
DateTime _date(Object? value) {
  final text = _string(value);
  final date = DateTime.tryParse(text);
  if (date == null || !date.isUtc || date.toIso8601String() != text) {
    throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
  }
  return date;
}

DateTime? _nullableDate(Object? value) => value == null ? null : _date(value);
T _enum<T extends Enum>(List<T> values, Object? raw) {
  final text = _string(raw);
  for (final value in values) {
    if (value.name == text) return value;
  }
  throw const SnapshotSchemaException(SnapshotSchemaError.malformed);
}
