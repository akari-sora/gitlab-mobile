import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';

Map<String, String> formParams(RequestOptions request) {
  final data = request.data;
  if (data is Map) {
    return data.map((key, value) => MapEntry('$key', '$value'));
  }
  if (data is String) return Uri.splitQueryString(data);
  fail('unexpected token body ${data.runtimeType}');
}

class FakeBrowser implements AuthorizationBrowser {
  Uri? authorizationUrl;
  Uri Function(Uri authorization, Uri callback)? respond;
  @override
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Uri callbackUrl,
  }) async {
    this.authorizationUrl = authorizationUrl;
    final builder =
        respond ??
        (authorization, callback) => Uri.parse(
          '$callback?code=synthetic-auth-code&state=${authorization.queryParameters['state']}',
        );
    return builder(authorizationUrl, callbackUrl);
  }
}

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');

  test('PKCE S256 matches the GitLab documented vector', () {
    expect(
      PkceSession.s256Challenge(
        'ks02i3jdikdo2k0dkfodf3m39rjfjsdk0wk349rj3jrhf',
      ),
      '2i0WFA-0AerkjQm4X4oDEhqA17QIAKNjXpagHBXmO_U',
    );
  });

  test(
    'authorize URL stays on the same instance with S256, state and redirect_uri',
    () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final pkce = PkceSession(
        clientId: 'synthetic-app-id',
        verifier: verifier,
        state: 'csrf-state',
      );
      final url = pkce.authorizeUrl(instance);
      expect(
        url.toString(),
        startsWith('https://example.com/gitlab/oauth/authorize?'),
      );
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(
        url.queryParameters['code_challenge'],
        PkceSession.s256Challenge(verifier),
      );
      expect(url.queryParameters['state'], 'csrf-state');
      expect(url.queryParameters['redirect_uri'], oauthRedirectUri);
      expect(url.queryParameters['client_id'], 'synthetic-app-id');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters.containsKey('client_secret'), isFalse);
      expect(
        url.queryParameters['code_challenge'],
        base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', ''),
      );
    },
  );

  test('production lookup has no GitLab.com Application ID', () {
    expect(
      oauthApplicationIdFor(GitLabInstance.parse('https://gitlab.com')),
      isNull,
    );
    expect(oauthApplicationIdFor(instance), isNull);
  });

  test(
    'token POST is same-instance /oauth/token with verifier and no client_secret',
    () async {
      final adapter = FakeAdapter((request) {
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        expect(request.headers['Authorization'], isNull);
        return jsonResponse({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      });
      final client = OAuthTokenClient(
        instance: instance,
        clientId: 'synthetic-app-id',
        dio: Dio()..httpClientAdapter = adapter,
      );
      final tokens = await client.exchange(
        code: 'auth-code',
        verifier: 'pkce-verifier',
      );
      expect(tokens.accessToken, 'new-access');
      expect(tokens.refreshToken, 'new-refresh');
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://example.com/gitlab/oauth/token');
      expect(request.followRedirects, isFalse);
      final body = formParams(request);
      expect(body['grant_type'], 'authorization_code');
      expect(body['code_verifier'], 'pkce-verifier');
      expect(body['code'], 'auth-code');
      expect(body['client_id'], 'synthetic-app-id');
      expect(body['redirect_uri'], oauthRedirectUri);
      expect(body.containsKey('client_secret'), isFalse);
    },
  );

  test('refresh POST replaces the access/refresh pair together', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({
        'access_token': 'rotated-access',
        'refresh_token': 'rotated-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      }),
    );
    final client = OAuthTokenClient(
      instance: instance,
      clientId: 'synthetic-app-id',
      dio: Dio()..httpClientAdapter = adapter,
    );
    const previous = OAuthCredential(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      clientId: 'synthetic-app-id',
    );
    final rotated = previous.replacedBy(await client.refresh(previous));
    expect(rotated.accessToken, 'rotated-access');
    expect(rotated.refreshToken, 'rotated-refresh');
    expect(rotated.accessToken, isNot('old-access'));
    expect(rotated.refreshToken, isNot('old-refresh'));
    final body = formParams(adapter.requests.single);
    expect(body['grant_type'], 'refresh_token');
    expect(body['refresh_token'], 'old-refresh');
    expect(body.containsKey('client_secret'), isFalse);
  });

  test(
    'GET 401 refreshes once then retries with the new Bearer token',
    () async {
      var users = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
            'expires_in': 7200,
          });
        }
        users += 1;
        if (users == 1) {
          return jsonResponse({'message': 'expired'}, status: 401);
        }
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        return jsonResponse({'id': 7, 'username': 'tester'});
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final oauth = OAuthTokenClient(
        instance: instance,
        clientId: 'synthetic-app-id',
        dio: dio,
      );
      late OAuthCredential persisted;
      final api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'synthetic-app-id',
        ),
        dio: dio,
        oauth: oauth,
        onOAuthRotated: (rotated) async {
          persisted = rotated;
        },
      );
      addTearDown(api.close);
      expect((await api.currentUser()).id, 7);
      expect(persisted.accessToken, 'rotated-access');
      expect(persisted.refreshToken, 'rotated-refresh');
      expect(adapter.requests.map((r) => '${r.method} ${r.uri.path}'), [
        'GET /gitlab/api/v4/user',
        'POST /gitlab/oauth/token',
        'GET /gitlab/api/v4/user',
      ]);
      expect(
        adapter.requests.first.headers['Authorization'],
        'Bearer old-access',
      );
      expect(adapter.requests.first.headers['PRIVATE-TOKEN'], isNull);
    },
  );

  test('write 401 refreshes the pair but does not replay the write', () async {
    var writes = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        return jsonResponse({
          'access_token': 'rotated-access',
          'refresh_token': 'rotated-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      writes += 1;
      return jsonResponse({'message': 'expired'}, status: 401);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final api = GitLabApi(
      instance: instance,
      credential: const OAuthCredential(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        clientId: 'synthetic-app-id',
      ),
      dio: dio,
      oauth: OAuthTokenClient(
        instance: instance,
        clientId: 'synthetic-app-id',
        dio: dio,
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.writeRecord('POST', ['projects'], {'name': 'x'}),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.kind,
          'kind',
          FailureKind.writeUncertain,
        ),
      ),
    );
    expect(writes, 1);
    expect(
      adapter.requests
          .where((r) => r.method == 'POST' && r.uri.path.endsWith('/projects'))
          .length,
      1,
    );
    expect((api.credential as OAuthCredential).accessToken, 'rotated-access');
  });

  test('callback parser accepts only code and state', () {
    expect(
      authorizationCodeFromCallback(
        Uri.parse('$oauthRedirectUri?code=abc&state=s1'),
        expectedState: 's1',
      ),
      'abc',
    );
    expect(
      () => authorizationCodeFromCallback(
        Uri.parse('$oauthRedirectUri?code=abc&state=s1&access_token=stolen'),
        expectedState: 's1',
      ),
      throwsFormatException,
    );
    expect(
      () => authorizationCodeFromCallback(
        Uri.parse('$oauthRedirectUri?code=abc&state=other'),
        expectedState: 's1',
      ),
      throwsFormatException,
    );
  });

  test('v1 PAT rows migrate and v2 OAuth rows round-trip', () async {
    final v1 = Account.fromSecureJson({
      'instance': 'https://example.com/gitlab',
      'user': {'id': 7, 'username': 'tester', 'name': 'Test'},
      'token': 'synthetic-test-token',
    });
    expect(v1.credential, isA<PatCredential>());
    expect(v1.token, 'synthetic-test-token');
    final oauth = Account(
      instance: instance,
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
      credential: const OAuthCredential(
        accessToken: 'oa',
        refreshToken: 'or',
        clientId: 'synthetic-app-id',
      ),
    );
    final encoded = oauth.toSecureJson();
    expect(encoded['kind'], 'oauth');
    expect(encoded.containsKey('token'), isFalse);
    expect(
      Account.fromSecureJson(Map<String, dynamic>.from(encoded)).credential,
      isA<OAuthCredential>(),
    );
  });

  test('connectOAuth exchanges PKCE and stores an OAuth credential', () async {
    final browser = FakeBrowser();
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        final body = formParams(request);
        expect(body['grant_type'], 'authorization_code');
        expect(body['code_verifier'], isNotEmpty);
        expect(body.containsKey('client_secret'), isFalse);
        return jsonResponse({
          'access_token': 'oauth-access',
          'refresh_token': 'oauth-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      expect(request.headers['Authorization'], 'Bearer oauth-access');
      expect(request.headers['PRIVATE-TOKEN'], isNull);
      return jsonResponse({'id': 7, 'username': 'tester'});
    });
    final store = MemoryAccountStore();
    final controller = controllerFor(
      store,
      adapter,
      browser: browser,
      applicationIdFor: (_) => 'synthetic-app-id',
      createOAuth: (inst, id) => OAuthTokenClient(
        instance: inst,
        clientId: id,
        dio: Dio()..httpClientAdapter = adapter,
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connectOAuth('https://example.com/gitlab');
    expect(controller.active?.user.id, 7);
    expect(controller.active?.credential, isA<OAuthCredential>());
    expect(
      browser.authorizationUrl?.queryParameters['code_challenge_method'],
      'S256',
    );
    expect(store.accounts.single.credential, isA<OAuthCredential>());
  });

  test(
    'connectOAuth without Application ID does not open the browser',
    () async {
      final browser = FakeBrowser();
      final adapter = FakeAdapter(
        (_) => jsonResponse({'id': 7, 'username': 'tester'}),
      );
      final controller = controllerFor(
        MemoryAccountStore(),
        adapter,
        browser: browser,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.connectOAuth('https://example.com/gitlab');
      expect(controller.active, isNull);
      expect(browser.authorizationUrl, isNull);
      expect(adapter.requests, isEmpty);
    },
  );
}
