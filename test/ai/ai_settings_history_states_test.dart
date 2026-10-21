import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_settings_page.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

const _account = 'https://synthetic.example/gitlab#7';
final _key = Uint8List.fromList(List<int>.filled(32, 7));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'unavailable storage disables history controls and retry recovers without deletion',
    (tester) async {
      final harness = await _Harness.create(
        historyEnabled: true,
        withKey: true,
      );
      addTearDown(harness.dispose);
      harness.store.historyKeyUnavailable = true;

      await harness.pump(tester);

      expect(harness.history.state(_account), AiHistoryState.unavailable);
      _expectHistoryControls(tester, enabled: false, clearEnabled: false);
      expect(find.text(l10n.aiHistoryUnavailable), findsOneWidget);
      expect(harness.store.destructiveCalls, isEmpty);

      harness.store.historyKeyUnavailable = false;
      await tester.tap(find.widgetWithText(TextButton, l10n.retryAction));
      await tester.pumpAndSettle();

      expect(harness.history.state(_account), AiHistoryState.ready);
      _expectHistoryControls(tester, enabled: true, clearEnabled: true);
      expect(harness.store.destructiveCalls, isEmpty);
    },
  );

  testWidgets(
    'missing key preserves encrypted files and never creates a key before confirmed clear',
    (tester) async {
      final harness = await _Harness.create(historyEnabled: true);
      addTearDown(harness.dispose);
      final preserved = await harness.historyFile('preserved.bin');

      await harness.pump(tester);

      expect(harness.history.state(_account), AiHistoryState.keyMissing);
      expect(find.text(l10n.aiHistoryKeyMissing), findsOneWidget);
      _expectHistoryControls(tester, enabled: false, clearEnabled: true);
      expect(preserved.existsSync(), isTrue);
      expect(harness.store.calls, isNot(contains('writeHistoryKey')));

      final clear = find.widgetWithText(OutlinedButton, l10n.aiClearHistory);
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiClearHistoryDetail), findsOneWidget);
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(preserved.existsSync(), isTrue);
      expect(harness.store.calls, isNot(contains('writeHistoryKey')));

      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.confirmAction));
      await tester.pumpAndSettle();

      expect(harness.history.state(_account), AiHistoryState.disabled);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('ai-history-switch')),
            )
            .value,
        isFalse,
      );
      expect(preserved.existsSync(), isFalse);
      expect(harness.store.calls, isNot(contains('writeHistoryKey')));
      expect(harness.store.calls, contains('deleteHistoryKey'));
    },
  );

  testWidgets(
    'cleaning tombstone retry finishes cleanup and enables controls',
    (tester) async {
      final harness = await _Harness.create(
        historyEnabled: true,
        withKey: true,
      );
      addTearDown(harness.dispose);
      await harness.store.setTombstone(_account);
      final pending = await harness.historyFile('pending.bin');

      await harness.pump(tester);

      expect(harness.history.state(_account), AiHistoryState.cleaning);
      expect(find.text(l10n.aiHistoryCleaning), findsOneWidget);
      _expectHistoryControls(tester, enabled: false, clearEnabled: false);

      await tester.tap(
        find.widgetWithText(TextButton, l10n.aiHistoryRetryCleanup),
      );
      await tester.pumpAndSettle();

      expect(harness.history.state(_account), AiHistoryState.disabled);
      _expectHistoryControls(tester, enabled: true, clearEnabled: true);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('ai-history-switch')),
            )
            .value,
        isFalse,
      );
      expect(pending.existsSync(), isFalse);
      expect(
        (await harness.store.memory.readTombstone(_account)).isFound,
        false,
      );
      expect(
        harness.store.calls,
        containsAllInOrder([
          'setTombstone',
          'deleteHistoryKey',
          'deleteAccount',
          'clearTombstone',
        ]),
      );
    },
  );

  testWidgets('read failure offers retry and returns to ready', (tester) async {
    var failRoot = true;
    final harness = await _Harness.create(
      historyEnabled: true,
      withKey: true,
      failRoot: () => failRoot,
    );
    addTearDown(harness.dispose);
    expect(await harness.history.load(_account), AiHistoryState.ready);
    expect(await harness.history.read(_account), isNull);
    expect(harness.history.state(_account), AiHistoryState.readFailed);

    await harness.pump(tester);

    expect(find.text(l10n.aiHistoryReadFailed), findsOneWidget);
    _expectHistoryControls(tester, enabled: false, clearEnabled: true);
    failRoot = false;
    await tester.tap(find.widgetWithText(TextButton, l10n.retryAction));
    await tester.pumpAndSettle();

    expect(harness.history.state(_account), AiHistoryState.ready);
    _expectHistoryControls(tester, enabled: true, clearEnabled: true);
    expect(harness.store.destructiveCalls, isEmpty);
  });

  for (final failure in ['file deletion', 'key deletion']) {
    testWidgets(
      'failed history $failure preserves the key and retry requires confirmation',
      (tester) async {
        var fileDeletionFails = failure == 'file deletion';
        final harness = await _Harness.create(
          historyEnabled: true,
          withKey: true,
          failRoot: () => fileDeletionFails,
        );
        addTearDown(harness.dispose);
        harness.store.deleteHistoryKeyFails = failure == 'key deletion';
        await harness.pump(tester);

        final clear = find.widgetWithText(OutlinedButton, l10n.aiClearHistory);
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        await tester.tap(clear);
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.confirmAction));
        await tester.pumpAndSettle();

        expect(harness.history.state(_account), AiHistoryState.readFailed);
        expect(harness.history.failure(_account)?.operation, 'clearHistory');
        expect(
          (await harness.store.memory.loadAccount(
            _account,
          )).value!.historyEnabled,
          isFalse,
        );
        expect(
          (await harness.store.memory.readHistoryKey(_account)).isFound,
          isTrue,
        );

        final retry = find.widgetWithText(TextButton, l10n.retryAction);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(find.text(l10n.aiClearHistoryDetail), findsOneWidget);
        await tester.tap(find.text(l10n.cancelAction));
        await tester.pumpAndSettle();
        expect(harness.history.state(_account), AiHistoryState.readFailed);
        expect(
          (await harness.store.memory.readHistoryKey(_account)).isFound,
          isTrue,
        );

        fileDeletionFails = false;
        harness.store.deleteHistoryKeyFails = false;
        await tester.tap(retry);
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.confirmAction));
        await tester.pumpAndSettle();

        expect(harness.history.state(_account), AiHistoryState.disabled);
        expect(
          (await harness.store.memory.readHistoryKey(_account)).isFound,
          isFalse,
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('ai-history-switch')),
              )
              .value,
          isFalse,
        );
      },
    );
  }
}

void _expectHistoryControls(
  WidgetTester tester, {
  required bool enabled,
  required bool clearEnabled,
}) {
  final historySwitch = tester.widget<SwitchListTile>(
    find.byKey(const ValueKey('ai-history-switch')),
  );
  final retention = tester.widget<DropdownButtonFormField<int>>(
    find.byType(DropdownButtonFormField<int>),
  );
  final tokenCap = tester.widget<TextFormField>(find.byType(TextFormField));
  final clear = tester.widget<OutlinedButton>(
    find.widgetWithText(OutlinedButton, l10n.aiClearHistory),
  );
  expect(historySwitch.onChanged != null, enabled);
  expect(retention.onChanged != null, enabled);
  expect(tokenCap.enabled, enabled);
  expect(clear.onPressed != null, clearEnabled);
}

final class _Harness {
  _Harness({
    required this.root,
    required this.store,
    required this.settings,
    required this.history,
  });

  static Future<_Harness> create({
    required bool historyEnabled,
    bool withKey = false,
    bool Function()? failRoot,
  }) async {
    final directory = Directory.systemTemp.createTempSync(
      'ai-settings-history-states-',
    );
    final store = _ForwardingStore();
    await store.memory.saveAccount(
      _account,
      AiAccountRecord(historyEnabled: historyEnabled),
    );
    if (withKey) await store.memory.writeHistoryKey(_account, _key);
    final settings = AiSettingsController(store);
    final history = AiHistoryCoordinator(
      store: store,
      files: AiHistoryFileStore(
        root: () async {
          if (failRoot?.call() == true) {
            throw PlatformException(code: 'synthetic-read-failure');
          }
          return directory;
        },
      ),
    );
    return _Harness(
      root: directory,
      store: store,
      settings: settings,
      history: history,
    );
  }

  final Directory root;
  final _ForwardingStore store;
  final AiSettingsController settings;
  final AiHistoryCoordinator history;

  Future<File> historyFile(String name) async {
    final directory = await history.files.directory(_account);
    directory.createSync(recursive: true);
    return File('${directory.path}/$name')..writeAsStringSync('encrypted');
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AiSettingsPage(
          settings: settings,
          history: history,
          accountKey: _account,
        ),
      ),
    );
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump();
      if (find
          .byKey(const ValueKey('ai-history-switch'))
          .evaluate()
          .isNotEmpty) {
        return;
      }
    }
    fail('AI settings page did not finish loading');
  }

  void dispose() {
    history.dispose();
    settings.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _ForwardingStore implements AiStore {
  final memory = MemoryAiStore();
  final calls = <String>[];
  bool historyKeyUnavailable = false;
  bool deleteHistoryKeyFails = false;

  Iterable<String> get destructiveCalls => calls.where(
    const {'deleteAccount', 'deleteHistoryKey', 'clearTombstone'}.contains,
  );

  void _call(String operation) => calls.add(operation);

  @override
  Future<AiStoreRead<List<AiProviderConfig>>> loadProviders() {
    _call('loadProviders');
    return memory.loadProviders();
  }

  @override
  Future<void> saveProviders(List<AiProviderConfig> providers) {
    _call('saveProviders');
    return memory.saveProviders(providers);
  }

  @override
  Future<AiStoreRead<String>> readProviderKey(String providerId) {
    _call('readProviderKey');
    return memory.readProviderKey(providerId);
  }

  @override
  Future<Map<String, String>> readAllProviderKeys(
    Iterable<String> providerIds,
  ) {
    _call('readAllProviderKeys');
    return memory.readAllProviderKeys(providerIds);
  }

  @override
  Future<void> saveProviderKey(
    String providerId,
    String key, {
    bool acknowledgeWarning = false,
  }) {
    _call('saveProviderKey');
    return memory.saveProviderKey(
      providerId,
      key,
      acknowledgeWarning: acknowledgeWarning,
    );
  }

  @override
  Future<void> deleteProviderKey(String providerId) {
    _call('deleteProviderKey');
    return memory.deleteProviderKey(providerId);
  }

  @override
  Future<AiStoreRead<AiAccountRecord>> loadAccount(String accountKey) {
    _call('loadAccount');
    return memory.loadAccount(accountKey);
  }

  @override
  Future<void> saveAccount(String accountKey, AiAccountRecord account) {
    _call('saveAccount');
    return memory.saveAccount(accountKey, account);
  }

  @override
  Future<List<String>> listAccountKeys() {
    _call('listAccountKeys');
    return memory.listAccountKeys();
  }

  @override
  Future<void> deleteAccount(String accountKey) {
    _call('deleteAccount');
    return memory.deleteAccount(accountKey);
  }

  @override
  Future<AiStoreRead<Uint8List>> readHistoryKey(String accountKey) {
    _call('readHistoryKey');
    if (historyKeyUnavailable) {
      return Future.value(
        const AiStoreRead.unavailable(
          AiStoreFailure(AiStoreFailureKind.unavailable, 'readHistoryKey'),
        ),
      );
    }
    return memory.readHistoryKey(accountKey);
  }

  @override
  Future<void> writeHistoryKey(String accountKey, Uint8List key) {
    _call('writeHistoryKey');
    return memory.writeHistoryKey(accountKey, key);
  }

  @override
  Future<void> deleteHistoryKey(String accountKey) {
    _call('deleteHistoryKey');
    if (deleteHistoryKeyFails) {
      throw PlatformException(code: 'synthetic-delete-key-failure');
    }
    return memory.deleteHistoryKey(accountKey);
  }

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) {
    _call('readTombstone');
    return memory.readTombstone(accountKey);
  }

  @override
  Future<void> setTombstone(String accountKey) {
    _call('setTombstone');
    return memory.setTombstone(accountKey);
  }

  @override
  Future<List<String>> listTombstones() {
    _call('listTombstones');
    return memory.listTombstones();
  }

  @override
  Future<void> clearTombstone(String accountKey) {
    _call('clearTombstone');
    return memory.clearTombstone(accountKey);
  }
}
