import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'failure.dart';
import 'instance.dart';
import 'models.dart';
import 'request_meter.dart';

import '../l10n/l10n.dart';

// RFC 3986 schemes cannot contain '_'; the Android applicationId still uses gitlab_mobile.
const oauthRedirectUri = 'io.gitlabmobile.app://oauth/callback';

/// Per-instance public Application IDs. Empty until a real ID is registered.
/// Tests inject a lookup; production must not invent a GitLab.com client.
String? oauthApplicationIdFor(GitLabInstance instance) {
  const ids = <String, String>{};
  final id = ids[instance.key];
  if (id == null || id.isEmpty) return null;
  return id;
}

abstract interface class AuthorizationBrowser {
  Future<Uri> authenticate({
    required Uri authorizationUrl,
    required Uri callbackUrl,
  });
}

final class PkceSession {
  PkceSession({
    required this.clientId,
    required this.verifier,
    required this.state,
    this.redirectUri = oauthRedirectUri,
    this.scope = 'api',
  });

  factory PkceSession.generate({
    required String clientId,
    Random? random,
    String redirectUri = oauthRedirectUri,
    String scope = 'api',
  }) {
    final rng = random ?? Random.secure();
    return PkceSession(
      clientId: clientId,
      verifier: randomToken(rng, 32),
      state: randomToken(rng, 16),
      redirectUri: redirectUri,
      scope: scope,
    );
  }

  final String clientId;
  final String verifier;
  final String state;
  final String redirectUri;
  final String scope;

  String get challenge => s256Challenge(verifier);

  Uri authorizeUrl(GitLabInstance instance) => instance.oauth('authorize', {
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'response_type': 'code',
    'state': state,
    'scope': scope,
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
  });

  static String s256Challenge(String verifier) => base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');

  static String randomToken(Random random, int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

String authorizationCodeFromCallback(
  Uri callback, {
  required String expectedState,
}) {
  final expected = Uri.parse(oauthRedirectUri);
  if (callback.scheme != expected.scheme || callback.host != expected.host) {
    throw InputFormatException(l10n.oauthCallbackUrlMismatch);
  }
  final params = callback.queryParameters;
  if (params.keys.any(
    (key) => const [
      'access_token',
      'private_token',
      'token',
    ].contains(key.toLowerCase()),
  )) {
    throw InputFormatException(l10n.oauthCallbackNoToken);
  }
  if ((params['error'] ?? '').isNotEmpty) {
    throw InputFormatException(
      params['error'] == 'access_denied'
          ? l10n.authorizationCanceled
          : l10n.gitlabDeniedAuthorization,
    );
  }
  if (!params.keys.every((key) => const ['code', 'state'].contains(key))) {
    throw InputFormatException(l10n.oauthCallbackCodeStateOnly);
  }
  if (params['state'] != expectedState) {
    throw InputFormatException(l10n.oauthStateMismatchAborted);
  }
  final code = params['code'];
  if (code == null || code.isEmpty) {
    throw InputFormatException(l10n.oauthCallbackMissingCode);
  }
  return code;
}

final class OAuthTokenClient {
  OAuthTokenClient({required this.instance, required this.clientId, Dio? dio})
    : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(seconds: 25);
    _dio.options.sendTimeout = const Duration(seconds: 15);
  }

  final GitLabInstance instance;
  final String clientId;
  final Dio _dio;

  Future<OAuthCredential> exchange({
    required String code,
    required String verifier,
    String redirectUri = oauthRedirectUri,
  }) => _token({
    'grant_type': 'authorization_code',
    'client_id': clientId,
    'code': code,
    'redirect_uri': redirectUri,
    'code_verifier': verifier,
  });

  Future<OAuthCredential> refresh(
    OAuthCredential current, {
    String redirectUri = oauthRedirectUri,
  }) => _token({
    'grant_type': 'refresh_token',
    'client_id': clientId,
    'refresh_token': current.refreshToken,
    'redirect_uri': redirectUri,
  });

  /// Refresh for identity probing, retaining a bounded `invalid_grant`
  /// distinction without treating other token endpoint errors as refusal.
  Future<OAuthCredential> refreshForIdentity(OAuthCredential current) async {
    try {
      final meter = RequestMeter.current;
      if (meter?.includeOAuthTokens == true) {
        final admission = meter!.beforeRequest;
        if (admission != null) await admission();
        meter.increment();
      }
      final response = await _dio.requestUri<ResponseBody>(
        instance.oauth('token'),
        data: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': current.refreshToken,
          'redirect_uri': oauthRedirectUri,
        },
        options: Options(
          method: 'POST',
          responseType: ResponseType.stream,
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status != null,
          headers: const {
            'Accept': 'application/json',
            'Cache-Control': 'no-store',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      final body = response.data;
      final isJson =
          (response.headers.value('content-type') ?? '')
              .split(';')
              .first
              .trim()
              .toLowerCase() ==
          'application/json';
      final bytes = BytesBuilder(copy: false);
      if (body != null) {
        final iterator = StreamIterator<Uint8List>(body.stream);
        final watch = Stopwatch()..start();
        final limit = status >= 200 && status < 300 ? 65536 : 4096;
        try {
          while (true) {
            final remaining = const Duration(seconds: 5) - watch.elapsed;
            if (remaining <= Duration.zero) {
              throw const ApiFailure(FailureKind.network);
            }
            if (!await iterator.moveNext().timeout(remaining)) break;
            final chunk = iterator.current;
            if (bytes.length + chunk.length > limit) {
              throw const ApiFailure(FailureKind.invalidResponse);
            }
            bytes.add(chunk);
          }
        } on TimeoutException {
          throw const ApiFailure(FailureKind.network);
        } finally {
          await iterator.cancel();
        }
      }
      Object? decoded;
      if (isJson) {
        try {
          decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        } on FormatException {
          // An unreadable error is not evidence of invalid_grant.
        }
      }
      if (status == 400 &&
          decoded is Map<String, dynamic> &&
          decoded['error'] == 'invalid_grant') {
        throw const ApiFailure(FailureKind.unauthenticated, status: 401);
      }
      if (status < 200 || status >= 300) throw ApiFailure.fromStatus(status);
      if (decoded is! Map<String, dynamic>) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      return OAuthCredential.fromTokenResponse(decoded, clientId: clientId);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<OAuthCredential> _token(Map<String, String> fields) async {
    if (fields.containsKey('client_secret')) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final uri = instance.oauth('token');
    try {
      final meter = RequestMeter.current;
      if (meter?.includeOAuthTokens == true) {
        final admission = meter!.beforeRequest;
        if (admission != null) await admission();
        meter.increment();
      }
      final response = await _dio.requestUri<Map<String, dynamic>>(
        uri,
        data: fields,
        options: Options(
          method: 'POST',
          responseType: ResponseType.json,
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status != null,
          headers: const {
            'Accept': 'application/json',
            'Cache-Control': 'no-store',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        throw const ApiFailure(FailureKind.redirectBlocked, status: 302);
      }
      if (status == 401 || status == 403) throw ApiFailure.fromStatus(status);
      if (status < 200 || status >= 300) throw ApiFailure.fromStatus(status);
      return OAuthCredential.fromTokenResponse(
        objectJson(response.data),
        clientId: clientId,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      throw const ApiFailure(FailureKind.network);
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}
