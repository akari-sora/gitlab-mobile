import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_secrets.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

void main() {
  test(
    'refresh observes provider keys loaded after an early refresh',
    () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider()]);
      await store.saveProviderKey('provider', 'stored-secret-value');
      final settings = AiSettingsController(store);
      final session = SessionController(_EmptyAccountStore());
      final secrets = KnownSecretsLive(session, settings);
      addTearDown(settings.dispose);
      addTearDown(session.dispose);

      await secrets.refresh();
      expect(secrets.current, isNot(contains('stored-secret-value')));

      await settings.initialize();
      await secrets.refresh();

      expect(secrets.current, contains('stored-secret-value'));
    },
  );

  test(
    'refresh keeps the conversation-lifetime union of provider keys',
    () async {
      final store = MemoryAiStore();
      await store.saveProviders(<AiProviderConfig>[_provider()]);
      await store.saveProviderKey('provider', 'first-secret-value');
      final settings = AiSettingsController(store);
      final session = SessionController(_EmptyAccountStore());
      final secrets = KnownSecretsLive(session, settings);
      addTearDown(settings.dispose);
      addTearDown(session.dispose);

      await settings.initialize();
      await secrets.refresh();
      expect(secrets.current, contains('first-secret-value'));

      await settings.saveProviderKey('provider', 'second-secret-value');
      await secrets.refresh();
      expect(
        secrets.current,
        containsAll(<String>['first-secret-value', 'second-secret-value']),
      );

      await settings.deleteProviderKey('provider');
      await secrets.refresh();
      expect(
        secrets.current,
        containsAll(<String>['first-secret-value', 'second-secret-value']),
      );
    },
  );

  test(
    'refresh always re-reads access and OAuth refresh credentials',
    () async {
      final settings = AiSettingsController(MemoryAiStore());
      final session = SessionController(_EmptyAccountStore());
      AccountCredential? credential = const PatCredential('old-access-token');
      final secrets = KnownSecretsLive(
        session,
        settings,
        readGitLabCredential: () => credential,
      );
      addTearDown(settings.dispose);
      addTearDown(session.dispose);

      await settings.initialize();
      await secrets.refresh();
      credential = const OAuthCredential(
        accessToken: 'new-access-token',
        refreshToken: 'new-refresh-token',
        clientId: 'synthetic-client',
      );
      await secrets.refresh();

      expect(
        secrets.current,
        containsAll(<String>[
          'old-access-token',
          'new-access-token',
          'new-refresh-token',
        ]),
      );
    },
  );
}

final class _EmptyAccountStore implements AccountStore {
  @override
  Future<List<Account>> load() async => const <Account>[];

  @override
  Future<String?> loadLastActive() async => null;

  @override
  Future<bool> loadSignOutPending() async => false;

  @override
  Future<void> save(List<Account> accounts) async {}

  @override
  Future<void> saveLastActive(String? key) async {}

  @override
  Future<void> saveSignOutPending(bool pending) async {}
}

AiProviderConfig _provider() => const AiProviderConfig(
  id: 'provider',
  name: 'Provider',
  presetId: 'custom',
  baseUrl: 'https://api.example.test/v1',
  format: AiFormat.responses,
  model: 'model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    streamUsage: true,
    toolChoice: true,
    replayChatExtras: true,
    includeEncryptedReasoning: true,
    promptCaching: true,
    requiresKey: true,
    maxRequestChars: 100000,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);
