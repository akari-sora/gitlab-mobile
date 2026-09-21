import 'package:flutter/foundation.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/oauth.dart';
import 'account_store.dart';

typedef ApiFactory =
    GitLabApi Function(GitLabInstance instance, AccountCredential credential);
typedef ApplicationIdLookup = String? Function(GitLabInstance instance);

final class SessionController extends ChangeNotifier {
  SessionController(
    this.store, {
    ApiFactory? createApi,
    ApplicationIdLookup? applicationIdFor,
    AuthorizationBrowser? browser,
    OAuthTokenClient Function(GitLabInstance instance, String clientId)?
    createOAuth,
  }) : _createApi = createApi,
       applicationIdFor = applicationIdFor ?? oauthApplicationIdFor,
       _browser = browser,
       _createOAuth =
           createOAuth ??
           ((instance, clientId) =>
               OAuthTokenClient(instance: instance, clientId: clientId));
  final AccountStore store;
  final ApiFactory? _createApi;
  final ApplicationIdLookup applicationIdFor;
  final AuthorizationBrowser? _browser;
  final OAuthTokenClient Function(GitLabInstance instance, String clientId)
  _createOAuth;
  List<Account> _accounts = [];
  List<Account> get accounts => List.unmodifiable(_accounts);
  Account? active;
  GitLabApi? api;
  GitLabApi? _pending;
  bool busy = false;
  bool initializing = true;
  String? message;
  int generation = 0;
  int _operation = 0;
  bool _disposed = false;

  bool _current(int operation) => !_disposed && operation == _operation;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final loaded = await store.load();
      if (!_disposed) _accounts = loaded;
    } catch (_) {
      if (!_disposed) message = '無法讀取安全儲存；不會退回明文保存。請重新加入帳號。';
    } finally {
      initializing = false;
      _emit();
    }
    // A saved account is explicitly selected and /user is revalidated.
  }

  Future<void> connect(String instanceText, String rawToken) async {
    if (busy || initializing || _disposed) return;
    final ticket = ++_operation;
    busy = true;
    message = null;
    _emit();
    GitLabApi? candidate;
    try {
      final instance = GitLabInstance.parse(instanceText);
      final token = rawToken.trim();
      candidate = _client(instance, PatCredential(token));
      _pending = candidate;
      final user = await candidate.currentUser();
      if (!_current(ticket)) return;
      final account = Account(instance: instance, user: user, token: token);
      final updated = [
        ..._accounts.where((a) => a.key != account.key),
        account,
      ];
      await store.save(updated);
      // A secure-store write already in flight cannot be cancelled. It may
      // retain the new saved account, but MUST NOT activate a stale session.
      if (!_disposed) _accounts = updated;
      if (!_current(ticket)) return;
      _activate(account, candidate);
      candidate = null;
    } on FormatException catch (error) {
      if (_current(ticket)) {
        message =
            error.message.contains('Token') ||
                error.message.contains('實例') ||
                error.message.contains('HTTPS')
            ? error.message
            : '回應格式無法辨識；未啟用此帳號。';
      }
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        message = error.kind == FailureKind.unauthenticated
            ? '無法驗證這個 Token。請確認 Token 未過期，並具備 api 或 read_api 權限。'
            : '${error.title}。${error.detail}';
      }
    } catch (_) {
      if (_current(ticket)) message = '無法安全保存帳號；未啟用此連線。';
    } finally {
      candidate?.close();
      _pending = null;
      busy = false;
      _emit();
    }
  }

  Future<void> select(Account saved) async {
    if (busy || initializing || _disposed) return;
    endSession();
    final ticket = ++_operation;
    busy = true;
    message = null;
    _emit();
    GitLabApi? candidate;
    try {
      candidate = _client(saved.instance, saved.credential);
      _pending = candidate;
      final user = await candidate.currentUser();
      if (!_current(ticket)) return;
      if (user.id != saved.user.id) {
        throw const ApiFailure(FailureKind.unauthenticated);
      }
      _activate(
        Account(
          instance: saved.instance,
          user: user,
          credential: saved.credential,
        ),
        candidate,
      );
      candidate = null;
    } on ApiFailure catch (error) {
      if (_current(ticket)) message = '${error.title}。${error.detail}';
    } catch (_) {
      if (_current(ticket)) message = '帳號重新驗證失敗；未切換至此帳號。';
    } finally {
      candidate?.close();
      _pending = null;
      busy = false;
      _emit();
    }
  }

  Future<void> connectOAuth(String instanceText) async {
    if (busy || initializing || _disposed) return;
    final ticket = ++_operation;
    busy = true;
    message = null;
    _emit();
    GitLabApi? candidate;
    try {
      final instance = GitLabInstance.parse(instanceText);
      final clientId = applicationIdFor(instance);
      final browser = _browser;
      if (clientId == null || clientId.isEmpty) {
        message = '這個實例尚未設定 OAuth 應用。請使用 Personal Access Token。';
        return;
      }
      if (browser == null) {
        message = '無法開啟系統瀏覽器完成授權。';
        return;
      }
      final pkce = PkceSession.generate(clientId: clientId);
      final callback = await browser.authenticate(
        authorizationUrl: pkce.authorizeUrl(instance),
        callbackUrl: Uri.parse(pkce.redirectUri),
      );
      if (!_current(ticket)) return;
      final code = authorizationCodeFromCallback(
        callback,
        expectedState: pkce.state,
      );
      final oauth = _createOAuth(instance, clientId);
      final tokens = await oauth.exchange(
        code: code,
        verifier: pkce.verifier,
        redirectUri: pkce.redirectUri,
      );
      if (!_current(ticket)) return;
      candidate = _client(instance, tokens, oauth: oauth);
      _pending = candidate;
      final user = await candidate.currentUser();
      if (!_current(ticket)) return;
      final account = Account(
        instance: instance,
        user: user,
        credential: tokens,
      );
      final updated = [
        ..._accounts.where((a) => a.key != account.key),
        account,
      ];
      await store.save(updated);
      if (!_disposed) _accounts = updated;
      if (!_current(ticket)) return;
      _activate(account, candidate);
      candidate = null;
    } on FormatException catch (error) {
      if (_current(ticket)) {
        message =
            error.message.contains('授權') ||
                error.message.contains('實例') ||
                error.message.contains('HTTPS')
            ? error.message
            : '授權回應無法辨識；未啟用此帳號。';
      }
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        message = error.kind == FailureKind.unauthenticated
            ? '無法完成 GitLab 授權。請確認應用設定與權限後重試。'
            : '${error.title}。${error.detail}';
      }
    } catch (_) {
      if (_current(ticket)) message = '無法完成授權或安全保存帳號；未啟用此連線。';
    } finally {
      candidate?.close();
      _pending = null;
      busy = false;
      _emit();
    }
  }

  GitLabApi _client(
    GitLabInstance instance,
    AccountCredential credential, {
    OAuthTokenClient? oauth,
  }) {
    final oauthClient =
        oauth ??
        switch (credential) {
          OAuthCredential(:final clientId) => _createOAuth(instance, clientId),
          PatCredential() => null,
        };
    return (_createApi ??
        ((inst, cred) => GitLabApi(
          instance: inst,
          credential: cred,
          oauth: oauthClient,
          onOAuthRotated: _persistRotated,
        )))(instance, credential);
  }

  Future<void> _persistRotated(OAuthCredential rotated) async {
    final current = active;
    if (current == null || current.credential is! OAuthCredential) return;
    final updated = Account(
      instance: current.instance,
      user: current.user,
      credential: rotated,
    );
    active = updated;
    final accounts = [
      ..._accounts.where((item) => item.key != updated.key),
      updated,
    ];
    await store.save(accounts);
    if (!_disposed) {
      _accounts = accounts;
      _emit();
    }
  }

  void _activate(Account account, GitLabApi client) {
    api?.close();
    active = account;
    api = client;
    generation++;
  }

  /// Local only: does NOT revoke a PAT on GitLab. Cancels pending sign-in too.
  void endSession() {
    _operation++;
    _pending?.close();
    api?.close();
    api = null;
    active = null;
    generation++;
    _emit();
  }

  Future<void> remove(Account account) async {
    if (busy || initializing || _disposed) return;
    busy = true;
    message = null;
    _emit();
    try {
      final updated = _accounts.where((a) => a.key != account.key).toList();
      await store.save(updated);
      if (_disposed) return;
      _accounts = updated;
      if (active?.key == account.key) endSession();
    } catch (_) {
      if (!_disposed) message = '移除安全儲存失敗；請重試。';
    } finally {
      busy = false;
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    _pending?.close();
    api?.close();
    super.dispose();
  }
}
