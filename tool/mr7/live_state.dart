import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'sandbox_contract.dart';

const mr7LiveRunWindow = Duration(minutes: 10);
const mr7LiveConfirmationWindow = Duration(minutes: 5);

/// Opening recovery material never creates keys, repairs data or changes entries.
final class Mr7LiveState {
  Mr7LiveState(this.root);
  final Directory root;

  /// Direct host callers use the same durable boundary as the Python wrapper.
  /// Existing or incomplete state is refused, never replaced.
  static Future<Mr7LiveState> create(
    Directory root,
    Mr7SandboxSession session,
    DateTime deadlineAt,
  ) async {
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const Mr7Refused('recoveryPermissions');
    }
    final chmod = await Process.run('chmod', ['700', root.path]);
    if (chmod.exitCode != 0) throw const Mr7Refused('recoveryPermissions');
    final state = Mr7LiveState(root);
    state._private(root.path, directory: true);
    for (final name in ['journal', 'run.json', 'journal-key.json']) {
      if (FileSystemEntity.typeSync('${root.path}/$name', followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const Mr7Refused('recoveryStateExists');
      }
    }
    await state.journalRoot.create();
    final journalChmod = await Process.run('chmod', [
      '700',
      state.journalRoot.path,
    ]);
    if (journalChmod.exitCode != 0) {
      throw const Mr7Refused('recoveryPermissions');
    }
    final account = '${session.instance}#${session.expectedUserId}';
    final key = AiHistoryCipher.newKey();
    final data = <String, Object?>{
      'schema': 1,
      'nonce': session.nonce,
      'projectPath': '${session.namespace}/mr7-${session.nonce}',
      'projectId': null,
      'instance': session.instance.toString(),
      'namespace': session.namespace,
      'expectedUserId': session.expectedUserId,
      'journalAccount': account,
      'journalDirectory': 'journal',
      'journalKeySha256': sha256.convert(key).toString(),
      'deadlineAt': deadlineAt.toUtc().toIso8601String(),
    };
    for (final entry in {
      'journal-key.json': <String, Object?>{
        'account': account,
        'key': base64Encode(key),
      },
      'run.json': data,
    }.entries) {
      final file = File('${root.path}/${entry.key}');
      await file.create(exclusive: true);
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) throw const Mr7Refused('recoveryPermissions');
      await file.writeAsString('${jsonEncode(entry.value)}\n', flush: true);
    }
    await state.update({});
    return state;
  }

  void _private(String path, {bool directory = false}) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            (directory
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file) ||
        (FileStat.statSync(path).mode & 0x1ff) != (directory ? 0x1c0 : 0x180)) {
      throw const Mr7Refused('recoveryPermissions');
    }
  }

  Map<String, dynamic> read() {
    _private(root.path, directory: true);
    final file = File('${root.path}/run.json');
    _private(file.path);
    if (file.lengthSync() > 16384) throw const Mr7Refused('recoveryState');
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map<String, dynamic> ||
        data['instance'] != 'https://gitlab.com' ||
        data['expectedUserId'] is! int ||
        (data['expectedUserId'] as int) <= 0 ||
        data['namespace'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(data['namespace'] as String) ||
        data['nonce'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(data['nonce'] as String) ||
        data['projectPath'] != '${data['namespace']}/mr7-${data['nonce']}' ||
        data['journalDirectory'] != 'journal' ||
        data['journalAccount'] !=
            '${data['instance']}#${data['expectedUserId']}' ||
        data['deadlineAt'] is! String ||
        DateTime.tryParse(data['deadlineAt'] as String) == null ||
        (data['projectId'] != null &&
            (data['projectId'] is! int || (data['projectId'] as int) <= 0))) {
      throw const Mr7Refused('recoveryState');
    }
    return data;
  }

  void validateIntent(Mr7SandboxSession session) {
    final data = read();
    if (data['nonce'] != session.nonce ||
        data['namespace'] != session.namespace ||
        data['expectedUserId'] != session.expectedUserId ||
        data['instance'] != session.instance.toString()) {
      throw const Mr7Refused('recoveryIntent');
    }
    readKey();
  }

  Uint8List readKey() {
    final data = read();
    final file = File('${root.path}/journal-key.json');
    if (!file.existsSync()) throw const Mr7Refused('journalKeyMissing');
    _private(file.path);
    if (file.lengthSync() > 4096) throw const Mr7Refused('journalKeyInvalid');
    final key = jsonDecode(file.readAsStringSync());
    if (key is! Map ||
        key['account'] != data['journalAccount'] ||
        key['key'] is! String) {
      throw const Mr7Refused('journalKeyForeign');
    }
    final bytes = base64Decode(key['key'] as String);
    if (bytes.length != 32) throw const Mr7Refused('journalKeyInvalid');
    if (sha256.convert(bytes).toString() != data['journalKeySha256']) {
      throw const Mr7Refused('journalUnreadableOrForeignKey');
    }
    return bytes;
  }

  Directory get journalRoot => Directory('${root.path}/journal');
  AiWriteJournal openJournal() {
    final data = read();
    _private(journalRoot.path, directory: true);
    return AiWriteJournal(
      keys: _LiveJournalKeys(data['journalAccount'] as String, readKey()),
      applicationSupport: journalRoot,
      processId: 'mr7-live-${data['nonce']}',
    );
  }

  Future<void> update(Map<String, Object?> values) async {
    final data = read()..addAll(values);
    final staging = File('${root.path}/run.json.new');
    await staging.create(exclusive: true);
    final result = await Process.run('chmod', ['600', staging.path]);
    if (result.exitCode != 0) throw const Mr7Refused('recoveryPermissions');
    await staging.writeAsString('${jsonEncode(data)}\n', flush: true);
    await staging.rename('${root.path}/run.json');
    final sync = await Process.run('python3', [
      '-c',
      'import os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); os.fsync(fd); os.close(fd)',
      root.path,
    ]);
    if (sync.exitCode != 0) throw const Mr7Refused('recoverySync');
  }

  Future<void> recordProject(int id) => update({'projectId': id});

  Future<Map<String, Object?>> reconcile() async {
    try {
      final data = read();
      final journal = openJournal();
      final account = data['journalAccount'] as String;
      if (await journal.keyStatus(account) != AiJournalKeyStatus.found) {
        throw const Mr7Refused('journalUnreadableOrForeignKey');
      }
      final bytes = await AiJournalFiles(journalRoot).read(account);
      final raw = bytes == null
          ? <String, Object?>{'entries': <Object?>[]}
          : await AiHistoryCipher.decryptJson(
              bytes,
              readKey(),
              account,
              AiJournalFiles.fileName,
              maxPlaintextBytes: AiWriteJournal.ciphertextLimit,
            );
      final originals = {
        for (final row in (raw['entries'] as List).cast<Map<String, Object?>>())
          row['execution']: row,
      };
      return {
        'status': 'PASS',
        'projectPath': data['projectPath'],
        'projectId': data['projectId'],
        'stopReason': data['stopReason'],
        'deadlineAt': data['deadlineAt'],
        'entries': [
          for (final entry in journal.entries(account))
            {
              'executionId': entry.executionId,
              'operation': entry.operationId,
              'targetIds': {
                for (final key in entry.writeKeys)
                  for (final part in key.parts)
                    if (RegExp(r'^(project|group):[0-9]+$').hasMatch(part))
                      part.split(':').last
                    else if (RegExp(
                      r'^[0-9]+$|^gid://gitlab/[A-Za-z]+/[0-9]+$',
                    ).hasMatch(part))
                      part,
              }.toList(),
              'state': entry.state.name,
              'createdAt': originals[entry.executionId]?['createdAt'],
              'dispatchedAt': entry.dispatchedAt?.toIso8601String(),
            },
        ],
      };
    } on Mr7Refused catch (error) {
      return {'status': 'FAIL', 'reason': error.code};
    } on Object {
      return {'status': 'FAIL', 'reason': 'journalUnreadableOrForeignKey'};
    }
  }
}

final class _LiveJournalKeys implements AiJournalKeyStore {
  _LiveJournalKeys(this.account, this.key);
  final String account;
  final Uint8List key;
  @override
  Future<AiStoreRead<Uint8List>> readKey(String accountKey) async =>
      accountKey == account
      ? AiStoreRead.found(Uint8List.fromList(key))
      : const AiStoreRead.absent();
  @override
  Future<AiStoreRead<DateTime>> readResetPending(String accountKey) async =>
      const AiStoreRead.absent();
  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) async =>
      const AiStoreRead.absent();
  @override
  Future<Set<String>> inventoryAccounts() async => {account};
  @override
  Future<void> writeKey(String accountKey, Uint8List key) async =>
      throw const Mr7Refused('journalKeyImmutable');
  @override
  Future<void> deleteKey(String accountKey) async =>
      throw const Mr7Refused('journalKeyImmutable');
  @override
  Future<void> writeResetPending(
    String accountKey,
    DateTime confirmedAt,
  ) async => throw const Mr7Refused('journalKeyImmutable');
  @override
  Future<void> deleteResetPending(String accountKey) async =>
      throw const Mr7Refused('journalKeyImmutable');
}
