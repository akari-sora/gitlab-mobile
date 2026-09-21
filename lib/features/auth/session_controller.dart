import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/oauth.dart';
import 'account_store.dart';

typedef ApiFactory =
    GitLabApi Function(
      GitLabInstance instance,
      AccountCredential credential,
      OAuthTokenClient? oauth,
      Future<void> Function(OAuthCredential rotated) onOAuthRotated,
    );
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
  bool resuming = false;
  Account? resumingAccount;
  String? message;
  int generation = 0;
  int _operation = 0;
  bool _disposed = false;

  /// Mirrors the stored sign-out marker. A fresh controller learns the same
  /// fact from [AccountStore.loadSignOutPending] and will not auto-resume.
  /// A failed key deletion keeps this true even when the marker write itself
  /// did not land, so a later [initialize] on this controller will not resume.
  bool pendingSignOutCleanup = false;
  int _lastActiveSerial = 0;
  bool _lastActiveIdle = true;
  Future<void> _lastActiveTail = Future<void>.value();
  int _accountsSerial = 0;
  bool _accountsIdle = true;
  Future<void> _accountsTail = Future<void>.value();

  bool _current(int operation) => !_disposed && operation == _operation;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    final ticket = ++_operation;
    try {
      try {
        final loaded = await store.load();
        if (!_current(ticket)) return;
        _accounts = loaded;
      } catch (_) {
        if (_current(ticket)) {
          message = '無法讀取安全儲存；不會退回明文保存。請重新加入帳號。';
        }
        return;
      }
      // In-memory cleanup survives a marker write that never landed. A stored
      // marker, or an unreadable one, also blocks auto-resume.
      var signOutPending = pendingSignOutCleanup;
      try {
        if (await store.loadSignOutPending()) signOutPending = true;
      } catch (_) {
        signOutPending = true;
      }
      String? lastKey;
      try {
        lastKey = await store.loadLastActive();
      } catch (_) {
        lastKey = null;
      }
      if (!_current(ticket)) return;
      pendingSignOutCleanup = signOutPending;
      // Resume only when a remembered key exists and sign-out cleanup finished.
      if (signOutPending) return;
      final match = _accountForKey(lastKey);
      if (match == null) return;
      resuming = true;
      resumingAccount = match;
      message = null;
      _emit();
      if (!_current(ticket)) return;
      GitLabApi? candidate;
      try {
        candidate = _client(match.instance, match.credential, account: match);
        _pending = candidate;
        final user = await candidate.currentUser();
        if (!_current(ticket)) return;
        if (user.id != match.user.id) {
          throw const ApiFailure(FailureKind.unauthenticated);
        }
        final credential = candidate.credential;
        _activate(
          Account(instance: match.instance, user: user, credential: credential),
          candidate,
        );
        candidate = null;
      } on ApiFailure catch (error) {
        if (_current(ticket)) {
          message = '${error.title}。${error.detail}';
          // Drop the remembered key only when the credential itself is dead.
          // Transient failures keep it so the next launch can retry.
          if (error.kind == FailureKind.unauthenticated) {
            try {
              await _enqueueLastActive(null);
            } catch (_) {}
          }
        }
      } catch (_) {
        if (_current(ticket)) {
          message = '帳號重新驗證失敗；未切換至此帳號。';
        }
      } finally {
        if (candidate != null) {
          candidate.close();
          if (identical(_pending, candidate)) _pending = null;
        } else if (_current(ticket)) {
          _pending = null;
        }
      }
    } finally {
      if (_current(ticket)) {
        initializing = false;
        resuming = false;
        resumingAccount = null;
      }
      if (!_disposed) _emit();
    }
  }

  Account? _accountForKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final account in _accounts) {
      if (account.key == key) return account;
    }
    return null;
  }

  Future<void> connect(String instanceText, String rawToken) async {
    if (busy || initializing || resuming || _disposed) return;
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
      final account = Account(
        instance: instance,
        user: user,
        credential: candidate.credential,
      );
      final previous = List<Account>.of(_accounts);
      _remember(account);
      final staged = _accounts;
      try {
        await _enqueueAccountSave();
      } catch (_) {
        if (_current(ticket) && identical(_accounts, staged)) {
          _accounts = previous;
        }
        rethrow;
      }
      // A secure-store write already in flight cannot be cancelled. It may
      // retain the new saved account, but MUST NOT activate a stale session.
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
      _releaseCandidate(candidate, ticket);
    }
  }

  Future<void> select(Account saved) async {
    if (initializing || resuming || _disposed) return;
    final ticket = ++_operation;
    busy = true;
    message = null;
    _emit();
    GitLabApi? candidate;
    try {
      final cleared = await _commitSignOut();
      if (!_current(ticket)) return;
      if (!cleared) {
        message = '無法清除自動登入記錄；請重試登出。';
        _emit();
        return;
      }
      candidate = _client(saved.instance, saved.credential, account: saved);
      _pending = candidate;
      final user = await candidate.currentUser();
      if (!_current(ticket)) return;
      if (user.id != saved.user.id) {
        throw const ApiFailure(FailureKind.unauthenticated);
      }
      final credential = candidate.credential;
      _activate(
        Account(instance: saved.instance, user: user, credential: credential),
        candidate,
      );
      candidate = null;
    } on ApiFailure catch (error) {
      if (_current(ticket)) message = '${error.title}。${error.detail}';
    } catch (_) {
      if (_current(ticket)) message = '帳號重新驗證失敗；未切換至此帳號。';
    } finally {
      _releaseCandidate(candidate, ticket);
    }
  }

  Future<void> connectOAuth(String instanceText) async {
    if (busy || initializing || resuming || _disposed) return;
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
        credential: candidate.credential,
      );
      final previous = List<Account>.of(_accounts);
      _remember(account);
      final staged = _accounts;
      try {
        await _enqueueAccountSave();
      } catch (_) {
        if (_current(ticket) && identical(_accounts, staged)) {
          _accounts = previous;
        }
        rethrow;
      }
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
      _releaseCandidate(candidate, ticket);
    }
  }

  GitLabApi _client(
    GitLabInstance instance,
    AccountCredential credential, {
    OAuthTokenClient? oauth,
    Account? account,
  }) {
    final oauthClient =
        oauth ??
        switch (credential) {
          OAuthCredential(:final clientId) => _createOAuth(instance, clientId),
          PatCredential() => null,
        };
    Future<void> onRotated(OAuthCredential rotated) =>
        _persistRotated(rotated, account);
    final factory = _createApi;
    if (factory != null) {
      return factory(instance, credential, oauthClient, onRotated);
    }
    return GitLabApi(
      instance: instance,
      credential: credential,
      oauth: oauthClient,
      onOAuthRotated: onRotated,
    );
  }

  /// Persists a refresh that happened before [active] is set (resume/select)
  /// as well as one for the already active account. A rotation for a different
  /// account is ignored.
  Future<void> _persistRotated(
    OAuthCredential rotated,
    Account? candidate,
  ) async {
    final current = active;
    final Account? source;
    if (current == null) {
      source = candidate;
    } else if (candidate == null || current.key == candidate.key) {
      source = current;
    } else {
      source = null;
    }
    if (source == null || source.credential is! OAuthCredential) return;
    final updated = Account(
      instance: source.instance,
      user: source.user,
      credential: rotated,
    );
    final previous = List<Account>.of(_accounts);
    final previousActive = active;
    _remember(updated);
    final staged = _accounts;
    try {
      await _enqueueAccountSave();
    } catch (_) {
      if (identical(_accounts, staged)) {
        _accounts = previous;
        active = previousActive;
      }
      rethrow;
    }
    if (!_disposed) _emit();
  }

  void _remember(Account account) {
    _accounts = [
      ..._accounts.where((item) => item.key != account.key),
      account,
    ];
    if (active?.key == account.key) active = account;
  }

  /// Account-list writes run one at a time. Each write snapshots [_accounts]
  /// when it actually starts, so a stale pre-activation rotation cannot
  /// overwrite a newer list that landed while an older save was in flight.
  /// A later call skips an earlier write that has not started.
  Future<void> _enqueueAccountSave() {
    final serial = ++_accountsSerial;
    final result = _accountsIdle
        ? _writeAccounts(serial)
        : _accountsTail.then((_) => _writeAccounts(serial));
    _accountsIdle = false;
    final tail = result.catchError((Object _) => Future<void>.value());
    _accountsTail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_accountsTail, tail)) _accountsIdle = true;
      }),
    );
    return result;
  }

  Future<void> _writeAccounts(int serial) async {
    if (serial != _accountsSerial) return;
    final snapshot = List<Account>.of(_accounts);
    await store.save(snapshot);
  }

  void _releaseCandidate(GitLabApi? candidate, int ticket) {
    if (candidate != null) {
      candidate.close();
      if (identical(_pending, candidate)) _pending = null;
    } else if (_current(ticket)) {
      _pending = null;
    }
    if (_current(ticket)) busy = false;
    _emit();
  }

  void _activate(Account account, GitLabApi client) {
    api?.close();
    active = account;
    api = client;
    generation++;
    unawaited(
      _enqueueLastActive(
        account.key,
      ).catchError((Object _) => Future<void>.value()),
    );
  }

  /// Last-active writes run one at a time. A later call supersedes an earlier
  /// one: if it was queued before the earlier write started, the earlier write
  /// is skipped; if the earlier write was already in flight, its result is
  /// ignored and the later write overwrites it. When nothing is in flight the
  /// next write starts immediately, so a sign-in persists before the caller
  /// continues.
  ///
  /// [signOut] stores the failure marker before deleting the key and clears
  /// that marker only after the deletion succeeds. A non-null [key] (a real
  /// sign-in) also clears the marker once its own write succeeds.
  Future<void> _enqueueLastActive(String? key, {bool signOut = false}) {
    final serial = ++_lastActiveSerial;
    final result = _lastActiveIdle
        ? _writeLastActive(serial, key, signOut: signOut)
        : _lastActiveTail.then(
            (_) => _writeLastActive(serial, key, signOut: signOut),
          );
    _lastActiveIdle = false;
    final tail = result.catchError((Object _) => Future<void>.value());
    _lastActiveTail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_lastActiveTail, tail)) _lastActiveIdle = true;
      }),
    );
    return result;
  }

  Future<void> _writeLastActive(
    int serial,
    String? key, {
    required bool signOut,
  }) async {
    if (serial != _lastActiveSerial) return;
    if (!signOut) {
      try {
        await store.saveLastActive(key);
        if (serial != _lastActiveSerial) return;
        if (key != null) {
          await store.saveSignOutPending(false);
          if (!_disposed) pendingSignOutCleanup = false;
        }
      } catch (error, stack) {
        if (serial != _lastActiveSerial) return;
        Error.throwWithStackTrace(error, stack);
      }
      return;
    }
    // Marker, then key deletion, then clear the marker. A marker-write
    // failure still deletes the key and is surfaced to the caller.
    Object? markerError;
    StackTrace? markerStack;
    try {
      await store.saveSignOutPending(true);
      if (!_disposed) pendingSignOutCleanup = true;
    } catch (error, stack) {
      markerError = error;
      markerStack = stack;
      if (!_disposed) pendingSignOutCleanup = true;
    }
    if (serial != _lastActiveSerial) {
      if (markerError != null) {
        Error.throwWithStackTrace(
          markerError,
          markerStack ?? StackTrace.current,
        );
      }
      return;
    }
    try {
      await store.saveLastActive(null);
    } catch (error, stack) {
      try {
        await store.saveSignOutPending(true);
      } catch (_) {}
      if (!_disposed) pendingSignOutCleanup = true;
      if (serial != _lastActiveSerial) return;
      Error.throwWithStackTrace(error, stack);
    }
    if (serial != _lastActiveSerial) return;
    if (markerError != null) {
      Error.throwWithStackTrace(markerError, markerStack ?? StackTrace.current);
    }
    try {
      await store.saveSignOutPending(false);
      if (serial != _lastActiveSerial) return;
      if (!_disposed) pendingSignOutCleanup = false;
    } catch (error, stack) {
      if (!_disposed) pendingSignOutCleanup = true;
      if (serial != _lastActiveSerial) return;
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Drops the in-memory session and waits for the sign-out storage sequence.
  /// Does not take a new operation ticket; callers that must stay current
  /// reserve one before awaiting this.
  Future<bool> _commitSignOut() async {
    _pending?.close();
    _pending = null;
    api?.close();
    api = null;
    active = null;
    resuming = false;
    resumingAccount = null;
    initializing = false;
    generation++;
    pendingSignOutCleanup = true;
    _emit();
    try {
      await _enqueueLastActive(null, signOut: true);
      return true;
    } catch (_) {
      pendingSignOutCleanup = true;
      return false;
    }
  }

  /// Local sign-out. Does not revoke the token on GitLab.
  ///
  /// The in-memory session is cancelled before any storage I/O, so the UI
  /// leaves the account immediately. Remembered-account writes are serialised
  /// by [_enqueueLastActive]: a later write wins, and a stale result is ignored.
  ///
  /// Auto-resume in [initialize] runs only when [AccountStore.loadLastActive]
  /// returns a key and sign-out cleanup is not pending. Cleanup writes the
  /// marker, deletes the key even if that marker write fails, and clears the
  /// marker only after the deletion succeeds. A failed marker write or a
  /// failed deletion keeps auto-login disarmed.
  Future<void> endSession() async {
    if (_disposed) return;
    final ticket = ++_operation;
    busy = false;
    final cleared = await _commitSignOut();
    if (!_current(ticket) || cleared) return;
    message = '無法清除自動登入記錄；請重試登出。';
    _emit();
  }

  Future<void> remove(Account account) async {
    if (busy || initializing || resuming || _disposed) return;
    final ticket = ++_operation;
    busy = true;
    message = null;
    _emit();
    final previous = List<Account>.of(_accounts);
    final staged = _accounts.where((item) => item.key != account.key).toList();
    _accounts = staged;
    try {
      await _enqueueAccountSave();
      if (!_current(ticket)) return;
      if (active?.key == account.key) {
        final cleared = await _commitSignOut();
        if (_current(ticket) && !cleared) {
          message = '無法清除自動登入記錄；請重試登出。';
        }
      }
    } catch (_) {
      if (_current(ticket) && identical(_accounts, staged)) {
        _accounts = previous;
      }
      if (_current(ticket)) message = '移除安全儲存失敗；請重試。';
    } finally {
      if (_current(ticket)) busy = false;
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
