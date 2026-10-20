import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/oauth.dart';
import 'account_store.dart';
import '../../shared/resume_target.dart';
import '../../shared/artifact_storage.dart';

import '../../l10n/l10n.dart';
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
  ResumeTarget? _pendingResumeTarget;
  ResumeTarget? get pendingResumeTarget => _pendingResumeTarget;

  void setPendingResumeTarget(ResumeTarget? target) {
    _pendingResumeTarget = target;
  }

  ResumeTarget? takeResumeTarget() {
    final target = _pendingResumeTarget;
    _pendingResumeTarget = null;
    return target;
  }

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
    if (!initializing) {
      // A delayed initialize supersedes whatever is in flight. Its candidate
      // is released here, because that operation's own release only clears
      // `busy` while its ticket is current.
      _pending?.close();
      _pending = null;
      _pendingResumeTarget = null;
      busy = false;
      resuming = false;
      resumingAccount = null;
      initializing = true;
      _emit();
    }
    try {
      try {
        final loaded = await store.load();
        if (!_current(ticket)) return;
        _accounts = loaded;
      } catch (_) {
        if (_current(ticket)) {
          message = l10n.secureStorageUnreadable;
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
          message = l10n.titleThenDetail(error.title, error.detail);
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
          message = l10n.accountReverifyNoSwitch;
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
            error is InputFormatException
            ? error.message
            : l10n.responseUnrecognizedNotEnabled;
      }
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        message = error.kind == FailureKind.unauthenticated
            ? l10n.cannotVerifyTokenScopes
            : l10n.titleThenDetail(error.title, error.detail);
      }
    } catch (_) {
      if (_current(ticket)) message = l10n.cannotStoreAccountSecurely;
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
        message = l10n.cannotClearAutoSignIn;
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
      if (_current(ticket)) message = l10n.titleThenDetail(error.title, error.detail);
    } catch (_) {
      if (_current(ticket)) message = l10n.accountReverifyNoSwitch;
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
        message = l10n.noOauthAppUsePat;
        return;
      }
      if (browser == null) {
        message = l10n.cannotOpenBrowserForAuth;
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
            error is InputFormatException
            ? error.message
            : l10n.authResponseUnrecognized;
      }
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        message = error.kind == FailureKind.unauthenticated
            ? l10n.cannotCompleteGitlabAuth
            : l10n.titleThenDetail(error.title, error.detail);
      }
    } catch (_) {
      if (_current(ticket)) message = l10n.authOrSecureStoreFailed;
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
    // A pending removal has already staged this identity out of the list.
    // A late credential refresh must not reintroduce it before the save.
    final sourceKey = source.key;
    if (!_accounts.any((account) => account.key == sourceKey)) return;
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
      // Roll back only what this rotation staged. A connect or remove that
      // replaced the list in the meantime queued its own save behind this
      // one and owns the list; reverting `active` alone would leave it on
      // the old token while the list and the live client hold the rotated
      // one. Within an untouched list, a select or sign-out that replaced
      // `active` owns the session, so it is restored only while it is still
      // the rotated instance installed above.
      if (identical(_accounts, staged)) {
        _accounts = previous;
        if (identical(active, updated)) active = previousActive;
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
  /// A later call skips an earlier write that has not started, except removal
  /// writes that need a confirmed snapshot before releasing their cleanup fence.
  Future<void> _enqueueAccountSave({void Function(List<Account>)? onSaved}) {
    final serial = ++_accountsSerial;
    final result = _accountsIdle
        ? _writeAccounts(serial, onSaved: onSaved)
        : _accountsTail.then((_) => _writeAccounts(serial, onSaved: onSaved));
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

  Future<void> _writeAccounts(
    int serial, {
    void Function(List<Account>)? onSaved,
  }) async {
    if (serial != _accountsSerial && onSaved == null) return;
    final snapshot = List<Account>.of(_accounts);
    await store.save(snapshot);
    onSaved?.call(snapshot);
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
  Future<void> endSession({bool switching = false}) async {
    if (!switching) {
      _pendingResumeTarget = null;
    }
    if (_disposed) return;
    final ticket = ++_operation;
    busy = false;
    final cleared = await _commitSignOut();
    if (!_current(ticket) || cleared) return;
    message = l10n.cannotClearAutoSignIn;
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
    final releaseMedia = suspendMarkdownMediaAccount(account);
    try {
      // Cleanup again inside the commit fence: a retained card may have started
      // after the shell's earlier file cleanup while other stores were cleared.
      await clearAccountArtifacts(account);
      await _enqueueAccountSave(
        onSaved: (saved) {
          // A superseding sign-out changes UI ownership, not a confirmed save.
          if (!saved.any((item) => item.key == account.key)) {
            markMarkdownMediaAccountRemoved(account);
          }
        },
      );
      if (!_current(ticket)) return;
      if (active?.key == account.key) {
        _pendingResumeTarget = null;
        final cleared = await _commitSignOut();
        if (_current(ticket) && !cleared) {
          message = l10n.cannotClearAutoSignIn;
        }
      }
    } catch (_) {
      if (_current(ticket) && identical(_accounts, staged)) {
        _accounts = previous;
      }
      if (_current(ticket)) message = l10n.removeSecureStorageFailed;
    } finally {
      releaseMedia();
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
    _pendingResumeTarget = null;
    super.dispose();
  }
}
