import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';

const _timeout = Timeout(Duration(seconds: 20));

final class _FakeBrowser implements AuthorizationBrowser {
  @override
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Uri callbackUrl,
  }) async => Uri.parse(
    '$callbackUrl?code=synthetic-code&state='
    '${authorizationUrl.queryParameters['state']}',
  );
}

SessionController _controller({
  required MemoryAccountStore store,
  required FakeAdapter adapter,
  required List<GitLabApi> created,
  AuthorizationBrowser? browser,
  String? Function(GitLabInstance)? applicationIdFor,
  OAuthTokenClient Function(GitLabInstance, String)? createOAuth,
}) => SessionController(
  store,
  browser: browser,
  applicationIdFor: applicationIdFor,
  createOAuth: createOAuth,
  createApi: (instance, credential, oauth, onOAuthRotated) {
    final api = GitLabApi(
      instance: instance,
      credential: credential,
      dio: Dio()..httpClientAdapter = adapter,
      oauth: oauth,
      onOAuthRotated: onOAuthRotated,
    );
    created.add(api);
    return api;
  },
);

void _expectBoundAfterActivation(
  SessionController controller,
  List<GitLabApi> created,
) {
  final active = controller.active!;
  final api = controller.api!;
  expect(api, same(created.single));
  expect(api.isReadCacheBound, isTrue);
  expect(api.readCacheAccountKey, active.key);
  expect(api.readCacheGeneration, controller.generation);
  expect(controller.generation, greaterThan(0));
}

void main() {
  test(
    'PAT login binds verified Account.key after generation advances',
    () async {
      final created = <GitLabApi>[];
      final adapter = FakeAdapter((request) {
        expect(created.single.isReadCacheBound, isFalse);
        return jsonResponse({'id': 7, 'username': 'pat-user'});
      });
      final controller = _controller(
        store: MemoryAccountStore(),
        adapter: adapter,
        created: created,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.connect('https://example.com/gitlab', 'synthetic-pat');

      _expectBoundAfterActivation(controller, created);
    },
    timeout: _timeout,
  );

  test(
    'OAuth login binds verified Account.key after generation advances',
    () async {
      final created = <GitLabApi>[];
      final apiAdapter = FakeAdapter((request) {
        expect(created.single.isReadCacheBound, isFalse);
        return jsonResponse({'id': 8, 'username': 'oauth-user'});
      });
      final tokenAdapter = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'synthetic-access',
          'refresh_token': 'synthetic-refresh',
          'token_type': 'bearer',
        }),
      );
      final controller = _controller(
        store: MemoryAccountStore(),
        adapter: apiAdapter,
        created: created,
        browser: _FakeBrowser(),
        applicationIdFor: (_) => 'synthetic-client',
        createOAuth: (instance, clientId) => OAuthTokenClient(
          instance: instance,
          clientId: clientId,
          dio: Dio()..httpClientAdapter = tokenAdapter,
        ),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.connectOAuth('https://example.com/gitlab');

      _expectBoundAfterActivation(controller, created);
    },
    timeout: _timeout,
  );

  test(
    'select binds the reverified saved account to the new generation',
    () async {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final saved = Account(
        instance: instance,
        user: const GitLabUser(id: 9, username: 'saved', name: 'Saved'),
        token: 'synthetic-saved-pat',
      );
      final store = MemoryAccountStore()..accounts = <Account>[saved];
      final created = <GitLabApi>[];
      final adapter = FakeAdapter((request) {
        expect(created.single.isReadCacheBound, isFalse);
        return jsonResponse({'id': 9, 'username': 'saved'});
      });
      final controller = _controller(
        store: store,
        adapter: adapter,
        created: created,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.generation, 0);
      await controller.select(saved);

      _expectBoundAfterActivation(controller, created);
      expect(controller.api?.readCacheAccountKey, saved.key);
    },
    timeout: _timeout,
  );

  test(
    'auto-resume binds only after the remembered account is reverified',
    () async {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final saved = Account(
        instance: instance,
        user: const GitLabUser(
          id: 10,
          username: 'remembered',
          name: 'Remembered',
        ),
        token: 'synthetic-remembered-pat',
      );
      final store = MemoryAccountStore()
        ..accounts = <Account>[saved]
        ..lastActive = saved.key;
      final created = <GitLabApi>[];
      final adapter = FakeAdapter((request) {
        expect(created.single.isReadCacheBound, isFalse);
        return jsonResponse({'id': 10, 'username': 'remembered'});
      });
      final controller = _controller(
        store: store,
        adapter: adapter,
        created: created,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      _expectBoundAfterActivation(controller, created);
      expect(controller.api?.readCacheAccountKey, saved.key);
    },
    timeout: _timeout,
  );

  test(
    'repeated binding disables the cache and drops cached content',
    () async {
      var requests = 0;
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final api = GitLabApi(
        instance: instance,
        token: 'synthetic-pat',
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((_) {
            requests += 1;
            return jsonResponse({'id': 2, 'title': 'cached'});
          }),
      );
      addTearDown(api.close);
      final key = '${instance.key}#7';
      api.bindReadCache(key, 1);
      await api.cachedRecord(<String>['projects', '1', 'issues', '2']);
      await api.cachedRecord(<String>['projects', '1', 'issues', '2']);
      expect(requests, 1);

      api.bindReadCache(key, 2);

      expect(api.isReadCacheBound, isFalse);
      expect(api.readCacheAccountKey, isNull);
      expect(api.readCacheGeneration, isNull);
      await api.cachedRecord(<String>['projects', '1', 'issues', '2']);
      expect(requests, 2);
    },
    timeout: _timeout,
  );

  test(
    'mismatched repeated binding disables and clears cached content',
    () async {
      var requests = 0;
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final api = GitLabApi(
        instance: instance,
        token: 'synthetic-pat',
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((_) {
            requests += 1;
            return jsonResponse({'id': 2, 'title': 'cached'});
          }),
      );
      addTearDown(api.close);
      api.bindReadCache('${instance.key}#7', 1);
      await api.cachedRecord(<String>['projects', '1', 'issues', '2']);
      await api.cachedRecord(<String>['projects', '1', 'issues', '2']);
      expect(requests, 1);

      api.bindReadCache('${instance.key}#8', 1);

      expect(api.isReadCacheBound, isFalse);
      await api.cachedRecord(<String>['projects', '1', 'issues', '2']);
      expect(requests, 2);
    },
    timeout: _timeout,
  );
}
