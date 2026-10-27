import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'session_test.dart' show MemoryAccountStore;

final _stamp = DateTime.utc(2026, 10, 20);
final _large = AiConversation(
  items: List<AiChatItem>.generate(
    28,
    (index) => AiUserItem(text: String.fromCharCode(97 + index % 26) * 16000),
  ),
);

class _Fixture {
  _Fixture(this.root, this.history, this.session, this.futureFile, this.index);
  final Directory root;
  final AiHistoryCoordinator history;
  final SessionController session;
  final File futureFile;
  final File? index;

  static Future<_Fixture> create(
    int futureAccount, {
    bool futureIndex = false,
  }) async {
    final root = Directory.systemTemp.createTempSync('ai-fix4-history-');
    final store = MemoryAiStore();
    final history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
    );
    final accounts = List<Account>.generate(
      5,
      (index) => Account(
        instance: GitLabInstance.parse(
          'https://synthetic-$index.example/gitlab',
        ),
        user: GitLabUser(
          id: index + 1,
          username: 'u$index',
          name: 'User $index',
        ),
        token: 'synthetic-token-$index',
      ),
    );
    final accountStore = MemoryAccountStore()..accounts = accounts;
    final session = SessionController(
      accountStore,
      readCache: accountStore.readCache,
    );
    addTearDown(() {
      session.dispose();
      history.dispose();
      root.deleteSync(recursive: true);
    });
    File? futureFile;
    File? indexFile;
    var ordinal = 0;
    for (var accountIndex = 0; accountIndex < accounts.length; accountIndex++) {
      final account = accounts[accountIndex];
      final key = Uint8List.fromList(
        List<int>.generate(32, (index) => (accountIndex * 37 + index) & 0xff),
      );
      await store.saveAccount(
        account.key,
        AiAccountRecord(historyEnabled: true),
      );
      await store.writeHistoryKey(account.key, key);
      final dir = await history.files.directory(account.key)
        ..createSync(recursive: true);
      final count = !futureIndex && accountIndex == 4 ? 29 : 30;
      for (var value = 0; value < count; value++) {
        final id = value.toRadixString(16).padLeft(32, '0');
        final name = 'c_$id.v1.bin';
        final unsupported = accountIndex == futureAccount && value == 0;
        final bytes = await AiHistoryCipher.encryptJson(
          <String, Object?>{
            'version': unsupported ? 2 : 1,
            'id': id,
            'updatedAt': _stamp.toIso8601String(),
            'stopReason': null,
            'display': aiDisplayJson(
              unsupported
                  ? AiConversation(items: [AiUserItem(text: 'future')])
                  : _large,
            ),
          },
          key,
          account.key,
          name,
        );
        final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
        file.setLastModifiedSync(
          unsupported
              ? _stamp.subtract(const Duration(days: 10))
              : _stamp.subtract(Duration(minutes: 400 - ordinal++)),
        );
        if (unsupported) futureFile = file;
      }
      if (futureIndex && accountIndex == futureAccount) {
        indexFile = File('${dir.path}/index.v1.bin')
          ..writeAsBytesSync(
            await AiHistoryCipher.encryptJson(
              <String, Object?>{'version': 2, 'entries': const <Object?>[]},
              key,
              account.key,
              'index.v1.bin',
            ),
          );
      }
      final bytes = dir.listSync().whereType<File>().fold<int>(
        0,
        (sum, file) => sum + file.lengthSync(),
      );
      expect(bytes, lessThan(AiHistoryFileStore.accountByteLimit));
    }
    final bytes = root
        .listSync(recursive: true)
        .whereType<File>()
        .fold<int>(0, (sum, file) => sum + file.lengthSync());
    expect(bytes, lessThan(AiHistoryFileStore.deviceByteLimit));
    await session.initialize();
    return _Fixture(root, history, session, futureFile!, indexFile);
  }

  AiSavedConversation get newConversation => AiSavedConversation(
    id: 'f' * 32,
    updatedAt: _stamp,
    conversation: _large,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup preserves v2 data in the second of five accounts', () async {
    final fixture = await _Fixture.create(1, futureIndex: true);
    final conversationHash = sha256.convert(
      fixture.futureFile.readAsBytesSync(),
    );
    final indexHash = sha256.convert(fixture.index!.readAsBytesSync());
    await fixture.history.startRecovery(fixture.session);
    expect(fixture.futureFile.existsSync(), isTrue);
    expect(
      sha256.convert(fixture.futureFile.readAsBytesSync()),
      conversationHash,
    );
    expect(sha256.convert(fixture.index!.readAsBytesSync()), indexHash);
    expect(
      fixture.history.notice(fixture.session.accounts[1].key),
      l10n.aiHistoryUnsupported,
    );
    expect(
      await fixture.history.save(
        fixture.session.accounts.last.key,
        fixture.newConversation,
      ),
      AiHistorySaveResult.saved,
    );
    expect(
      sha256.convert(fixture.futureFile.readAsBytesSync()),
      conversationHash,
    );
    expect(sha256.convert(fixture.index!.readAsBytesSync()), indexHash);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Q1 save before recovery protects an unscanned v2 account', () async {
    final fixture = await _Fixture.create(0);
    final hash = sha256.convert(fixture.futureFile.readAsBytesSync());
    final result = await fixture.history.save(
      fixture.session.accounts.last.key,
      fixture.newConversation,
    );
    expect(
      result,
      anyOf(AiHistorySaveResult.saved, AiHistorySaveResult.storageLimit),
    );
    expect(fixture.futureFile.existsSync(), isTrue);
    expect(sha256.convert(fixture.futureFile.readAsBytesSync()), hash);
    await fixture.history.startRecovery(fixture.session);
    expect(
      fixture.history.notice(fixture.session.accounts.first.key),
      l10n.aiHistoryUnsupported,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'Q2 membership change restarts recovery and classifies remaining accounts',
    () async {
      final fixture = await _Fixture.create(4);
      final accounts = fixture.session.accounts.toList();
      final hash = sha256.convert(fixture.futureFile.readAsBytesSync());
      final recovery = fixture.history.startRecovery(fixture.session);
      await fixture.session.remove(accounts[2]);
      await recovery;
      expect(fixture.history.state(accounts[4].key), AiHistoryState.ready);
      expect(
        fixture.history.notice(accounts[4].key),
        l10n.aiHistoryUnsupported,
      );
      expect(
        await fixture.history.save(accounts.first.key, fixture.newConversation),
        AiHistorySaveResult.saved,
      );
      expect(fixture.futureFile.existsSync(), isTrue);
      expect(sha256.convert(fixture.futureFile.readAsBytesSync()), hash);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'protected capacity refusal uses a retryable notice and saves after space frees',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-fix4-notice-');
      final history = AiHistoryCoordinator(
        store: MemoryAiStore(),
        files: AiHistoryFileStore(root: () async => root, clock: () => _stamp),
      );
      addTearDown(() {
        history.dispose();
        root.deleteSync(recursive: true);
      });
      const account = 'synthetic';
      await history.enable(account);
      final foreign = await history.files.directory('unclassified')
        ..createSync(recursive: true);
      final protectedFile = File('${foreign.path}/c_${'a' * 32}.v1.bin');
      final handle = protectedFile.openSync(mode: FileMode.write);
      handle.truncateSync(AiHistoryFileStore.deviceByteLimit);
      handle.closeSync();
      final conversation = AiSavedConversation(
        id: 'b' * 32,
        updatedAt: _stamp,
        conversation: AiConversation(items: [AiUserItem(text: 'synthetic')]),
      );
      expect(
        await history.save(account, conversation),
        AiHistorySaveResult.storageLimit,
      );
      expect(protectedFile.existsSync(), isTrue);
      expect(history.storageLimitReached(account, conversation.id), isTrue);
      expect(
        history.notice(account, conversationId: conversation.id),
        l10n.aiHistoryCapacityLimit,
      );
      expect(
        history.notice(account, conversationId: conversation.id),
        isNot(l10n.aiHistoryStorageLimit),
      );
      foreign.deleteSync(recursive: true);
      expect(
        await history.save(account, conversation),
        AiHistorySaveResult.saved,
      );
      expect(history.storageLimitReached(account, conversation.id), isFalse);
      expect(history.notice(account, conversationId: conversation.id), isNull);
    },
  );

  test('loading only the key does not classify history for eviction', () async {
    final root = Directory.systemTemp.createTempSync('ai-fix4-load-');
    final store = MemoryAiStore();
    const account = 'synthetic';
    await store.saveAccount(account, AiAccountRecord(historyEnabled: true));
    await store.writeHistoryKey(account, Uint8List(32));
    final files = AiHistoryFileStore(root: () async => root);
    final history = AiHistoryCoordinator(store: store, files: files);
    addTearDown(() {
      history.dispose();
      root.deleteSync(recursive: true);
    });
    expect(files.canEvictAccount!(aiHistoryAccountSegment('unseen')), isFalse);
    await history.load(account);
    expect(history.state(account), AiHistoryState.ready);
    expect(files.canEvictAccount!(aiHistoryAccountSegment(account)), isFalse);
    await history.read(account);
    expect(files.canEvictAccount!(aiHistoryAccountSegment(account)), isTrue);
  });
}
