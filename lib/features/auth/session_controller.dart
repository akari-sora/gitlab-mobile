import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/instance_ca.dart';
import '../../core/models.dart';
import '../../core/oauth.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/rate_budget.dart';
import '../offline/offline_gate.dart';
import '../security/app_lock.dart';
import '../cache/read_cache_disk_backend.dart';
import '../cache/read_cache_disk_coordinator.dart';
import 'account_store.dart';
import 'instance_trust.dart';
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
typedef IdentityApiFactory =
    GitLabApi Function(
      GitLabInstance instance,
      AccountCredential credential,
      OAuthTokenClient? oauth,
      Future<void> Function(OAuthCredential rotated) onOAuthRotated,
      GitLabRateBudget rateBudget,
    );

/// How the sign-in screen repeats the operation that stopped at an
/// untrusted certificate, once a CA is imported for [instance].
enum UntrustedRetry { connect, connectOAuth, select }

/// The last connect, OAuth sign-in or account check ended with
/// [FailureKind.untrustedCertificate] for [instance].
final class UntrustedInstance {
  const UntrustedInstance({
    required this.instance,
    required this.retry,
    this.saved,
    this.certificate,
  });
  final GitLabInstance instance;
  final UntrustedRetry retry;

  /// The saved account to check again, for [UntrustedRetry.select].
  final Account? saved;

  /// What the server presented, when the handshake reported it.
  final RefusedCertificate? certificate;
}

final class SessionController extends ChangeNotifier {
  SessionController(
    this.store, {
    ApiFactory? createApi,
    IdentityApiFactory? createIdentityApi,
    ApplicationIdLookup? applicationIdFor,
    AuthorizationBrowser? browser,
    OAuthTokenClient Function(GitLabInstance instance, String clientId)?
    createOAuth,
    ReadCacheDiskCoordinator? readCache,
    AppLockController? appLock,
    DateTime Function()? clock,
    InstanceTrust? trust,
  }) : _createApi = createApi,
       _createIdentityApi = createIdentityApi,
       readCache = readCache ?? ReadCacheDiskCoordinator.instance,
       applicationIdFor = applicationIdFor ?? oauthApplicationIdFor,
       _browser = browser,
       _createOAuthOverride = createOAuth,
       trust = trust ?? InstanceTrust.memory() {
    this.readCache.claimStartupSession(this);
    offlineGate = OfflineGate(
      readCache: this.readCache,
      appLock: appLock,
      clock: clock,
    );
  }
  final AccountStore store;
  final ReadCacheDiskCoordinator readCache;

  /// CA certificates imported per instance. Every client this controller
  /// builds for an instance gets that instance's context (or the defaults).
  final InstanceTrust trust;

  /// Set when the last connect, OAuth sign-in or account check stopped at an
  /// untrusted certificate that a CA import can address; cleared when the
  /// next one starts. Never set for GitLab.com or for a server certificate
  /// outside its validity dates.
  UntrustedInstance? untrusted;

  /// The instance whose certificate the last operation refused, whether or
  /// not an import is offered; [importInstanceCa] rolls back on it.
  String? _refusedInstanceKey;
  final ApiFactory? _createApi;
  final IdentityApiFactory? _createIdentityApi;
  late final OfflineGate offlineGate;
  OfflineSession? offline;
  OfflineEligibility? _offlineEligibility;
  Future<OfflineEligibility?>? _qualification;
  Future<void>? _offlineProbeTask;
  Future<bool>? _earlyEntryTask;
  Completer<void>? _resumeDone;
  final _earlyValidationTickets = <int>{};
  String? get diskRetainedAccountKey => readCache.diskRetainedAccountKey;

  /// The account whose disk data signing in elsewhere deletes: the retained
  /// account once startup recovery has run, and until then the account the
  /// current startup decision keeps. [select] uses the same source, so a
  /// confirmation shown before it names the account it actually clears.
  String? get leavingDiskAccountKey {
    final decision = _readCacheStartupDecision;
    return readCache.diskRetainedAccountKey ??
        (decision != null && decision.readable && !decision.signOutPending
            ? decision.resumeAccountKey
            : null);
  }
  bool get canEnterOffline =>
      offlineModeEnabled &&
      resuming &&
      _offlineEligibility != null &&
      offlineGate.lockReadable;
  bool get offlineProbing => offlineGate.probing || _offlineProbeTask != null;

  int _offlineEntries = 0;

  /// True while offline read-only mode is being entered or is on. That mode
  /// allows no local AI writes (AGENTS.md:9), so `main`'s AI startup recovery
  /// starts no step while this holds and resumes once it clears.
  bool get localWritesClosed => offline != null || _offlineEntries > 0;

  /// Set by `main`: waits, bounded, for the AI startup recovery step already
  /// running to settle, and returns false if it did not. Offline entry closes
  /// [localWritesClosed] first and publishes [offline] only after this
  /// returned true, so no AI file is written once the mode is visible.
  Future<bool> Function()? settleLocalWrites;

  void bindOfflineAppLock(AppLockController lock) =>
      offlineGate.bindAppLock(lock);

  void _closeClient(GitLabApi? client) => client?.close(
    closeRateBudget: !identical(client.rateBudget, offlineGate.rateBudget),
  );

  Future<void> _acceptIdentity(String key) async {
    if (!readCache.configured) return;
    try {
      await readCache.deleteOfflineRefused(key);
    } on Object {
      // The coordinator keeps disk admission closed. Fresh online identity
      // proof remains valid even when marker removal cannot be confirmed.
    }
  }

  final ApplicationIdLookup applicationIdFor;
  final AuthorizationBrowser? _browser;
  final OAuthTokenClient Function(GitLabInstance instance, String clientId)?
  _createOAuthOverride;

  OAuthTokenClient _createOAuth(GitLabInstance instance, String clientId) =>
      _createOAuthOverride?.call(instance, clientId) ??
      OAuthTokenClient(
        instance: instance,
        clientId: clientId,
        securityContext: trust.securityContextFor(instance),
      );
  List<Account> _accounts = [];
  List<Account> get accounts => List.unmodifiable(_accounts);
  Account? active;
  GitLabApi? api;
  GitLabApi? _pending;
  bool busy = false;
  bool initializing = true;
  bool accountsLoaded = false;
  bool resuming = false;
  Account? resumingAccount;
  String? message;
  int generation = 0;
  static int _issuedGeneration = 0;
  void _advanceGeneration() => generation = ++_issuedGeneration;
  int _operation = 0;
  bool _disposed = false;
  bool get isDisposed => _disposed;
  final _disposal = Completer<void>();
  Future<void> get whenDisposed => _disposal.future;
  int _accountListRevision = 0;
  bool _accountsReadable = false;
  bool _signOutMarkerReadable = false;
  bool _lastActiveReadable = false;
  ReadCacheStartupDecision? _readCacheStartupDecision;
  ReadCacheStartupDecision? get readCacheStartupDecision =>
      _readCacheStartupDecision;
  final _readCacheClears = <String, Future<void>>{};

  /// The bounded result of each account's latest clear. Unlike
  /// [_readCacheClears] it does not wait for the I/O to drain, so it ends
  /// within the coordinator's barrier even when storage hangs.
  final _readCacheClearResults = <String, Future<DiskClearResult>>{};

  bool isReadCacheDecisionCurrent(ReadCacheStartupDecision decision) =>
      !_disposed &&
      readCache.ownsStartupSession(this) &&
      identical(decision, _readCacheStartupDecision) &&
      decision.operationTicket == _operation &&
      decision.accountListRevision == _accountListRevision;

  void _invalidateReadCacheDecision() {
    _readCacheStartupDecision = null;
    readCache.revokeStartup(this);
  }

  void _publishReadCacheDecision(String? resumeKey, {bool? signOutPending}) {
    _invalidateReadCacheDecision();
    _readCacheStartupDecision = ReadCacheStartupDecision(
      operationTicket: _operation,
      accountListRevision: _accountListRevision,
      accountsReadable: _accountsReadable,
      signOutMarkerReadable: _signOutMarkerReadable,
      lastActiveReadable: _lastActiveReadable,
      signOutPending: signOutPending ?? pendingSignOutCleanup,
      resumeAccountKey: resumeKey,
    );
  }

  void _setAccounts(List<Account> accounts) {
    final previous = _accounts.map((account) => account.key).toSet();
    final next = accounts.map((account) => account.key).toSet();
    _accounts = accounts;
    if (!setEquals(previous, next)) {
      _accountListRevision++;
      _invalidateReadCacheDecision();
    }
  }

  Future<DiskClearResult> _clearReadCache(
    DiskBinding binding,
    ReadCacheCleanupOperation operation, {
    void Function(ApiFailure)? onFailure,
  }) {
    // clear installs its full intent synchronously, before the caller can
    // close the old client or advance the visible session.
    final result = readCache.clear(
      binding,
      operation,
      sessionOwner: operation == ReadCacheCleanupOperation.signOut
          ? this
          : null,
      onFailure: onFailure,
    );
    _readCacheClearResults[binding.accountKey] = result;
    late final Future<void> tail;
    tail = result.then((_) => readCache.quiesced).then<void>((_) {
      if (identical(_readCacheClears[binding.accountKey], tail)) {
        _readCacheClears.remove(binding.accountKey);
      }
    });
    _readCacheClears[binding.accountKey] = tail;
    return result;
  }

  void _clearKnownCandidate(Account account) {
    if (_accountForKey(account.key) == null) return;
    if (readCache.diskRetainedAccountKey == account.key) {
      readCache.retainDiskAccount(null, sessionOwner: this);
    }
    unawaited(
      _clearReadCache(
        DiskBinding(accountKey: account.key, generation: generation),
        ReadCacheCleanupOperation.signOut,
      ),
    );
  }

  Future<void> _activateReadCache(DiskBinding binding) async {
    // The bounded clear result is not an I/O acknowledgement. A replacement
    // session waits for the old serialized work, and still checks ownership.
    await _readCacheClears[binding.accountKey];
    await readCache.quiesced;
    if (_disposed ||
        !readCache.ownsStartupSession(this) ||
        active?.key != binding.accountKey ||
        generation != binding.generation ||
        api == null) {
      return;
    }
    await readCache.activate(binding);
  }

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

  bool _current(int operation) =>
      !_disposed &&
      readCache.ownsStartupSession(this) &&
      operation == _operation;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_disposed || offline != null || !readCache.ownsStartupSession(this)) {
      return;
    }
    final ticket = ++_operation;
    _offlineEligibility = null;
    _invalidateReadCacheDecision();
    _accountsReadable = false;
    _signOutMarkerReadable = false;
    _lastActiveReadable = false;
    final loadedBeforeInitialize = accountsLoaded;
    accountsLoaded = false;
    if (!initializing) {
      // A delayed initialize supersedes whatever is in flight. Its candidate
      // is released here, because that operation's own release only clears
      // `busy` while its ticket is current.
      _closeClient(_pending);
      _pending = null;
      _pendingResumeTarget = null;
      busy = false;
      resuming = false;
      resumingAccount = null;
      initializing = true;
      _emit();
    } else if (loadedBeforeInitialize) {
      _emit();
    }
    try {
      try {
        final loaded = await store.load();
        if (!_current(ticket)) return;
        _setAccounts(loaded);
        _accountsReadable = true;
        accountsLoaded = true;
        _emit();
      } catch (_) {
        if (_current(ticket)) {
          message = l10n.secureStorageUnreadable;
        }
        return;
      }
      // Imported CAs are read before the first client is built. An
      // unreadable store leaves every instance on the default roots.
      if (!trust.loaded) {
        await trust.load();
        if (!_current(ticket)) return;
      }
      unawaited(
        trust.sweepOrphans({
          for (final account in _accounts) account.instance.key,
        }),
      );
      // In-memory cleanup survives a marker write that never landed. A stored
      // marker, or an unreadable one, also blocks auto-resume.
      var signOutPending = pendingSignOutCleanup;
      var markerReadable = false;
      try {
        if (await store.loadSignOutPending()) signOutPending = true;
        markerReadable = true;
      } catch (_) {
        signOutPending = true;
      }
      String? lastKey;
      var lastReadable = false;
      try {
        lastKey = await store.loadLastActive();
        lastReadable = true;
      } catch (_) {
        lastKey = null;
      }
      if (!_current(ticket)) return;
      _signOutMarkerReadable = markerReadable;
      _lastActiveReadable = lastReadable;
      pendingSignOutCleanup = signOutPending;
      final match = _accountForKey(lastKey);
      _publishReadCacheDecision(signOutPending ? null : match?.key);
      _emit();
      // Resume only when a remembered key exists and sign-out cleanup finished.
      if (signOutPending) return;
      if (match == null) return;
      resuming = true;
      resumingAccount = match;
      message = null;
      untrusted = null;
      _refusedInstanceKey = null;
      _emit();
      if (!_current(ticket)) return;
      offlineGate.stop();
      offlineGate.resetBudget();
      final qualification = _qualification = offlineGate.check(
        match,
        isCurrent: () => _current(ticket),
      );
      unawaited(
        qualification.then((value) {
          if (_current(ticket) && resuming) {
            _offlineEligibility = value;
            _emit();
          }
        }),
      );
      GitLabApi? candidate;
      final done = _resumeDone = Completer<void>();
      try {
        candidate = _client(
          match.instance,
          match.credential,
          account: match,
          identityCandidate: true,
        );
        _pending = candidate;
        final verdict = await offlineGate.probe(candidate.identityCheck);
        if (!_current(ticket)) return;
        final entry = _earlyEntryTask;
        if (entry != null) {
          await entry;
          if (!_current(ticket)) return;
        }
        if (_earlyValidationTickets.remove(ticket)) {
          await _handleOfflineVerdict(match, verdict, ticket: ticket);
          return;
        }
        if (!_current(ticket)) return;
        if (verdict is IdentityOk && verdict.user.id == match.user.id) {
          await _acceptIdentity(match.key);
          if (!_current(ticket)) return;
          _activate(
            Account(
              instance: match.instance,
              user: verdict.user,
              credential: candidate.credential,
            ),
            candidate,
          );
          candidate = null;
        } else if (verdict is IdentityNoVerdict) {
          final eligible = await qualification;
          if (!_current(ticket)) return;
          final entered =
              eligible != null &&
              await _enterOffline(
                eligible,
                ticket: ticket,
                reason: verdict.failure,
              );
          if (!_current(ticket)) return;
          if (entered) {
            offlineGate.scheduleRetry();
          } else {
            _showIdentityFailure(verdict, account: match);
          }
        } else {
          await _handleIdentityVerdict(match, verdict, ticket: ticket);
          if (_current(ticket)) _showIdentityFailure(verdict);
        }
      } catch (_) {
        if (_current(ticket)) message = l10n.accountReverifyNoSwitch;
      } finally {
        _earlyValidationTickets.remove(ticket);
        _closeClient(candidate);
        if (identical(_pending, candidate) || _current(ticket)) _pending = null;
        if (!done.isCompleted) done.complete();
        if (identical(_resumeDone, done)) _resumeDone = null;
      }
    } finally {
      if (_current(ticket)) {
        if (_readCacheStartupDecision == null) {
          _publishReadCacheDecision(null);
        }
        if (offline == null) {
          initializing = false;
          resuming = false;
          resumingAccount = null;
        }
      }
      if (!_disposed) _emit();
    }
  }

  void _showIdentityFailure(IdentityVerdict verdict, {Account? account}) {
    final failure =
        verdict.failure ?? const ApiFailure(FailureKind.unauthenticated);
    message = l10n.titleThenDetail(failure.title, failure.detail);
    if (account != null) {
      _noteUntrusted(failure, account.instance, UntrustedRetry.select, account);
    }
    _emit();
  }

  /// Offers a CA import only where one can help. GitLab.com's failure text
  /// already warns of interception (set by the client). A server
  /// certificate outside its validity dates gets its own message.
  void _noteUntrusted(
    ApiFailure failure,
    GitLabInstance instance,
    UntrustedRetry retry, [
    Account? saved,
  ]) {
    if (failure.kind != FailureKind.untrustedCertificate) return;
    _refusedInstanceKey = instance.key;
    if (instance.isGitLabCom) return;
    final refused = failure.refusedCertificate;
    if (refused != null && !refused.validAt(offlineGate.now)) {
      message = l10n.titleThenDetail(
        failure.title,
        l10n.serverCertificateNotValidNow,
      );
      return;
    }
    untrusted = UntrustedInstance(
      instance: instance,
      retry: retry,
      saved: saved,
      certificate: failure.refusedCertificate,
    );
  }

  /// Stores [certificate] for [instance] once the user confirmed it, then
  /// runs [retry] (the operation that stopped at the certificate). When the
  /// retry stops at the certificate again, the CA cannot help: the previous
  /// CA is restored, or the new one removed, and the message says so.
  /// Returns whether the new CA was kept. A client built before this keeps
  /// its own context. Throws [CaCertificateFailure], always for GitLab.com.
  Future<bool> importInstanceCa(
    GitLabInstance instance,
    InstanceCaCertificate certificate, {
    required Future<void> Function() retry,
  }) async {
    if (instance.isGitLabCom) {
      throw const CaCertificateFailure(CaCertificateProblem.gitLabCom);
    }
    if (_disposed || busy || offline != null) return false;
    final previous = trust.certificateFor(instance);
    await trust.save(instance, certificate);
    _refusedInstanceKey = null;
    await retry();
    if (_disposed || _refusedInstanceKey != instance.key) return true;
    const limit = Duration(seconds: 5);
    try {
      await (previous == null
              ? trust.remove(instance)
              : trust.save(instance, previous))
          .timeout(limit);
    } on Object {
      // A failed restore must not leave the rejected CA trusted: removal
      // forgets it in memory before its delete, even one that fails or hangs.
      try {
        await trust.remove(instance).timeout(limit);
      } on Object {
        // Forgotten for this run only: storage may still hold it, and the
        // next start's load trusts it again (follow-up in RESULT.md).
      }
    }
    if (_disposed) return false;
    untrusted = null;
    message = l10n.titleThenDetail(
      l10n.untrustedCertificateTitle,
      l10n.caImportDidNotHelp,
    );
    _emit();
    return false;
  }

  Future<bool> _handleIdentityVerdict(
    Account account,
    IdentityVerdict verdict, {
    required int ticket,
  }) async {
    var retained = true;
    if (!_current(ticket)) return retained;
    if (verdict is IdentityRefused401 ||
        (verdict is IdentityOk && verdict.user.id != account.user.id)) {
      retained = false;
      // clear() fences both namespaces synchronously, before its first await.
      _clearKnownCandidate(account);
      _leaveOffline(account);
      _publishReadCacheDecision(null);
      try {
        await _enqueueLastActive(null);
      } catch (_) {}
    } else if (verdict is IdentityRefused403) {
      try {
        await readCache.writeOfflineRefused(account.key, offlineGate.now);
      } catch (_) {
        if (!_current(ticket)) return retained;
        retained = false;
        _clearKnownCandidate(account);
        _publishReadCacheDecision(null);
        try {
          await _enqueueLastActive(null);
        } catch (_) {}
      }
      if (!_current(ticket)) return retained;
      _leaveOffline(account);
    }
    return retained;
  }

  void _leaveOffline(Account account) {
    final current = offline;
    if (current == null || current.account.key != account.key) return;
    readCache.closeOfflineReadOnly(
      DiskBinding(accountKey: account.key, generation: current.generation),
      sessionOwner: this,
    );
    offline = null;
    offlineGate.stop();
    _advanceGeneration();
    _emit();
  }

  Future<void> _handleOfflineVerdict(
    Account account,
    IdentityVerdict verdict, {
    required int ticket,
  }) async {
    bool current() =>
        _current(ticket) &&
        offline?.account.key == account.key &&
        offline?.validationTicket == ticket;
    if (!current()) return;
    if (verdict is IdentityOk && verdict.user.id == account.user.id) {
      await _acceptIdentity(account.key);
      if (!current()) return;
      offline?.connectionRestored = true;
      offlineGate.connectionSucceeded();
    } else if (verdict is IdentityNoVerdict) {
      offline
        ?..reason = verdict.failure
        ..connectionRestored = false;
      offlineGate.scheduleRetry();
    } else {
      final retained = await _handleIdentityVerdict(
        account,
        verdict,
        ticket: ticket,
      );
      if (!_current(ticket)) return;
      if (verdict is IdentityUnknown) _leaveOffline(account);
      if (retained) {
        _showIdentityFailure(verdict);
      } else {
        _reportOfflineDeletion(account);
      }
    }
    _emit();
  }

  /// §5.6: the offline account's data is unreadable at once and deleted in
  /// the background; the sign-in screen says so, then how the deletion ended.
  void _reportOfflineDeletion(Account account) {
    final username = account.user.username;
    final deleting = message = l10n.offlineSignInExpiredDeleting(username);
    _emit();
    // The bounded result, not the drain: a clear that times out leaves its
    // marker for the next start, and the screen says so at once.
    final clearing = _readCacheClearResults[account.key];
    void finished(bool complete) {
      if (_disposed || message != deleting) return;
      message = complete
          ? l10n.offlineSignInExpiredDeleted(username)
          : l10n.offlineSignInExpiredRetry(username);
      _emit();
    }

    if (clearing == null) {
      finished(
        !readCache.signedOutSnapshot.keys.any(
          (binding) => binding.accountKey == account.key,
        ),
      );
      return;
    }
    unawaited(
      clearing.then<void>(
        (result) => finished(result.complete),
        onError: (Object _, StackTrace _) => finished(false),
      ),
    );
  }

  Future<bool> enterOffline() async {
    if (!resuming || !offlineModeEnabled) return false;
    final ticket = _operation;
    final eligible = _offlineEligibility ?? await _qualification;
    if (eligible == null || !_current(ticket) || !resuming) return false;
    final existing = _earlyEntryTask;
    if (existing != null) return existing;
    _earlyValidationTickets.add(ticket);
    final entry = _earlyEntryTask = _enterOffline(eligible, ticket: ticket);
    try {
      final entered = await entry;
      if (!entered) _earlyValidationTickets.remove(ticket);
      return entered;
    } finally {
      if (identical(_earlyEntryTask, entry)) _earlyEntryTask = null;
    }
  }

  Future<bool> _enterOffline(
    OfflineEligibility eligible, {
    required int ticket,
    ApiFailure? reason,
  }) async {
    if (!offlineModeEnabled ||
        !_current(ticket) ||
        active != null ||
        offline != null ||
        !offlineGate.lockReadable ||
        !OfflineGate.recent(eligible.lastValidatedAt, offlineGate.now)) {
      return false;
    }
    _offlineEntries++;
    try {
      return await _enterOfflineClosed(eligible, ticket: ticket, reason: reason);
    } finally {
      _offlineEntries--;
      // A refused entry reopens AI recovery; a published one keeps it closed.
      if (offline == null && _offlineEntries == 0) _emit();
    }
  }

  Future<bool> _enterOfflineClosed(
    OfflineEligibility eligible, {
    required int ticket,
    ApiFailure? reason,
  }) async {
    final settle = settleLocalWrites;
    if (settle != null && !await settle()) return false;
    final nextGeneration = ++_issuedGeneration;
    final binding = DiskBinding(
      accountKey: eligible.account.key,
      generation: nextGeneration,
    );
    if (!await readCache.enterOfflineReadOnly(binding, sessionOwner: this)) {
      return false;
    }
    if (!_current(ticket) ||
        !offlineModeEnabled ||
        !offlineGate.lockReadable ||
        active != null ||
        offline != null ||
        !resuming) {
      readCache.closeOfflineReadOnly(binding, sessionOwner: this);
      return false;
    }
    _closeClient(api);
    api = null;
    active = null;
    generation = nextGeneration;
    offline = OfflineSession(
      account: eligible.account,
      validationTicket: ticket,
      lastValidatedAt: eligible.lastValidatedAt,
      generation: generation,
    )..reason = reason;
    readCache.retainDiskAccount(eligible.account.key, sessionOwner: this);
    initializing = false;
    resuming = false;
    resumingAccount = null;
    message = null;
    untrusted = null;
    _refusedInstanceKey = null;
    offlineGate.start(
      lastValidatedAt: eligible.lastValidatedAt,
      onProbe: () => probeOffline(manual: false),
      onExpire: () {
        if (offline?.account.key != eligible.account.key) return;
        _leaveOffline(eligible.account);
        message = l10n.offlineValidationExpired;
        _emit();
      },
    );
    _emit();
    return true;
  }

  /// A successful background check changes the banner. Explicit online retry
  /// validates again before giving the account a content-capable API client.
  Future<void> probeOffline({
    bool manual = true,
    bool switchOnline = false,
    int? projectId,
  }) {
    final current = offline;
    if (current == null || !offlineGate.recheckAge()) return Future.value();
    Future<void> joined(Future<void> task) => !switchOnline
        ? task
        : task.then((_) {
            if (identical(offline, current)) {
              return probeOffline(
                manual: false,
                switchOnline: true,
                projectId: projectId,
              );
            }
          });
    final task = _offlineProbeTask;
    if (task != null) return joined(task);
    if (offlineGate.probing) {
      return joined(_resumeDone?.future ?? Future.value());
    }
    late final Future<void> result;
    result =
        _probeOffline(
          current,
          manual: manual,
          switchOnline: switchOnline,
          projectId: projectId,
        ).whenComplete(() {
          if (identical(_offlineProbeTask, result)) _offlineProbeTask = null;
          _emit();
        });
    _offlineProbeTask = result;
    _emit();
    return result;
  }

  Future<void> _probeOffline(
    OfflineSession current, {
    required bool manual,
    required bool switchOnline,
    int? projectId,
  }) async {
    final ticket = ++_operation;
    current.validationTicket = ticket;
    final account = _accountForKey(current.account.key) ?? current.account;
    GitLabApi? candidate;
    try {
      final verdict = await offlineGate.probe(() {
        final client = candidate = _client(
          account.instance,
          account.credential,
          account: account,
          identityCandidate: true,
        );
        _pending = client;
        return client.identityCheck();
      }, manual: manual && !switchOnline);
      if (!_current(ticket) ||
          !identical(offline, current) ||
          current.validationTicket != ticket) {
        return;
      }
      if (switchOnline &&
          verdict is IdentityOk &&
          verdict.user.id == account.user.id &&
          candidate != null &&
          _current(ticket) &&
          identical(offline, current)) {
        await _acceptIdentity(account.key);
        if (!_current(ticket) || !identical(offline, current)) return;
        _activate(
          Account(
            instance: account.instance,
            user: verdict.user,
            credential: candidate!.credential,
          ),
          candidate!,
        );
        candidate = null;
        if (projectId != null) {
          _pendingResumeTarget = ResumeTarget(
            projectId: projectId,
            resource: 'repository',
          );
        }
      } else {
        await _handleOfflineVerdict(account, verdict, ticket: ticket);
      }
    } catch (_) {
      if (_current(ticket)) {
        _leaveOffline(account);
        message = l10n.accountReverifyNoSwitch;
      }
    } finally {
      _closeClient(candidate);
      if (identical(_pending, candidate)) _pending = null;
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
    if (offline != null ||
        busy ||
        initializing ||
        resuming ||
        _disposed ||
        !readCache.ownsStartupSession(this)) {
      return;
    }
    final ticket = ++_operation;
    _invalidateReadCacheDecision();
    busy = true;
    message = null;
    untrusted = null;
    _refusedInstanceKey = null;
    _emit();
    GitLabApi? candidate;
    GitLabInstance? target;
    try {
      final instance = target = GitLabInstance.parse(instanceText);
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
      await _acceptIdentity(account.key);
      if (!_current(ticket)) return;
      final previous = List<Account>.of(_accounts);
      _remember(account);
      final staged = _accounts;
      try {
        await _enqueueAccountSave();
      } catch (_) {
        if (_current(ticket) && identical(_accounts, staged)) {
          _setAccounts(previous);
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
        message = error is InputFormatException
            ? error.message
            : l10n.responseUnrecognizedNotEnabled;
      }
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        message = error.kind == FailureKind.unauthenticated
            ? l10n.cannotVerifyTokenScopes
            : l10n.titleThenDetail(error.title, error.detail);
        if (target != null) {
          _noteUntrusted(error, target, UntrustedRetry.connect);
        }
      }
    } catch (_) {
      if (_current(ticket)) message = l10n.cannotStoreAccountSecurely;
    } finally {
      _releaseCandidate(candidate, ticket);
    }
  }

  Future<void> select(Account saved) async {
    if (offline != null ||
        initializing ||
        resuming ||
        _disposed ||
        !readCache.ownsStartupSession(this)) {
      return;
    }
    // The current startup decision can still be waiting for its disk scan.
    // Preserve its selected account as well as a fully recovered one.
    final decision = _readCacheStartupDecision;
    final retainedKey = leavingDiskAccountKey;
    final retryRetained =
        active == null &&
        saved.key == retainedKey &&
        _accountForKey(saved.key) != null &&
        decision != null &&
        decision.readable &&
        !decision.signOutPending &&
        !pendingSignOutCleanup;
    final ticket = ++_operation;
    _invalidateReadCacheDecision();
    busy = true;
    message = null;
    untrusted = null;
    _refusedInstanceKey = null;
    _emit();
    GitLabApi? candidate;
    try {
      if (!retryRetained) {
        final cleared = await _commitSignOut(
          resumeAccountKey: _accountForKey(saved.key)?.key,
          retainedAccountKey: retainedKey,
        );
        if (!_current(ticket)) return;
        if (!cleared) {
          message = l10n.cannotClearAutoSignIn;
          _emit();
          return;
        }
      }
      candidate = _client(saved.instance, saved.credential, account: saved);
      _pending = candidate;
      final verdict = await candidate.identityCheck();
      if (!_current(ticket)) return;
      if (verdict is! IdentityOk || verdict.user.id != saved.user.id) {
        final retained = await _handleIdentityVerdict(
          saved,
          verdict,
          ticket: ticket,
        );
        if (!_current(ticket)) return;
        _publishReadCacheDecision(retryRetained && retained ? saved.key : null);
        _showIdentityFailure(verdict, account: saved);
        return;
      }
      await _acceptIdentity(saved.key);
      if (!_current(ticket)) return;
      final user = verdict.user;
      final credential = candidate.credential;
      _activate(
        Account(instance: saved.instance, user: user, credential: credential),
        candidate,
      );
      candidate = null;
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        if (error.kind == FailureKind.unauthenticated) {
          _clearKnownCandidate(saved);
          if (retryRetained) {
            try {
              await _enqueueLastActive(null);
            } catch (_) {}
            if (!_current(ticket)) return;
          }
        }
        _publishReadCacheDecision(
          retryRetained && error.kind != FailureKind.unauthenticated
              ? saved.key
              : null,
        );
        message = l10n.titleThenDetail(error.title, error.detail);
        _noteUntrusted(error, saved.instance, UntrustedRetry.select, saved);
      }
    } catch (_) {
      if (_current(ticket)) {
        if (retryRetained) _publishReadCacheDecision(saved.key);
        message = l10n.accountReverifyNoSwitch;
      }
    } finally {
      _releaseCandidate(candidate, ticket);
    }
  }

  Future<void> connectOAuth(String instanceText) async {
    if (offline != null ||
        busy ||
        initializing ||
        resuming ||
        _disposed ||
        !readCache.ownsStartupSession(this)) {
      return;
    }
    final ticket = ++_operation;
    _invalidateReadCacheDecision();
    busy = true;
    message = null;
    untrusted = null;
    _refusedInstanceKey = null;
    _emit();
    GitLabApi? candidate;
    GitLabInstance? target;
    try {
      final instance = target = GitLabInstance.parse(instanceText);
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
      await _acceptIdentity(account.key);
      if (!_current(ticket)) return;
      final previous = List<Account>.of(_accounts);
      _remember(account);
      final staged = _accounts;
      try {
        await _enqueueAccountSave();
      } catch (_) {
        if (_current(ticket) && identical(_accounts, staged)) {
          _setAccounts(previous);
        }
        rethrow;
      }
      if (!_current(ticket)) return;
      _activate(account, candidate);
      candidate = null;
    } on FormatException catch (error) {
      if (_current(ticket)) {
        message = error is InputFormatException
            ? error.message
            : l10n.authResponseUnrecognized;
      }
    } on ApiFailure catch (error) {
      if (_current(ticket)) {
        message = error.kind == FailureKind.unauthenticated
            ? l10n.cannotCompleteGitlabAuth
            : l10n.titleThenDetail(error.title, error.detail);
        if (target != null) {
          _noteUntrusted(error, target, UntrustedRetry.connectOAuth);
        }
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
    bool identityCandidate = false,
  }) {
    final oauthClient =
        oauth ??
        switch (credential) {
          OAuthCredential(:final clientId) => _createOAuth(instance, clientId),
          PatCredential() => null,
        };
    Future<void> onRotated(OAuthCredential rotated) =>
        _persistRotated(rotated, account);
    final identityFactory = _createIdentityApi;
    if (identityCandidate && identityFactory != null) {
      return identityFactory(
        instance,
        credential,
        oauthClient,
        onRotated,
        offlineGate.rateBudget,
      );
    }
    final factory = _createApi;
    if (factory != null) {
      return factory(instance, credential, oauthClient, onRotated);
    }
    return GitLabApi(
      instance: instance,
      credential: credential,
      oauth: oauthClient,
      onOAuthRotated: onRotated,
      rateBudget: identityCandidate ? offlineGate.rateBudget : null,
      securityContext: trust.securityContextFor(instance),
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
        _setAccounts(previous);
        if (identical(active, updated)) active = previousActive;
      }
      rethrow;
    }
    if (!_disposed) _emit();
  }

  void _remember(Account account) {
    _setAccounts([
      ..._accounts.where((item) => item.key != account.key),
      account,
    ]);
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
      _closeClient(candidate);
      if (identical(_pending, candidate)) _pending = null;
    } else if (_current(ticket)) {
      _pending = null;
    }
    if (_current(ticket)) busy = false;
    if (_current(ticket) && _readCacheStartupDecision == null) {
      _publishReadCacheDecision(active?.key);
    }
    _emit();
  }

  void _activate(Account account, GitLabApi client) {
    final leavingOffline = offline;
    if (leavingOffline != null) {
      readCache.closeOfflineReadOnly(
        DiskBinding(
          accountKey: leavingOffline.account.key,
          generation: leavingOffline.generation,
        ),
        sessionOwner: this,
      );
    }
    offline = null;
    _offlineEligibility = null;
    offlineGate.stop();
    // A new session for an already active account still follows C2's D1
    // departure rule. B8 applies only when there is no active session.
    final previous = active;
    if (previous?.key == account.key) {
      unawaited(
        _clearReadCache(
          DiskBinding(accountKey: previous!.key, generation: generation),
          ReadCacheCleanupOperation.signOut,
        ),
      );
    }
    // Fence every known other account before the new client is bound. The
    // coordinator drains and deletes those accounts asynchronously.
    final nextGeneration = ++_issuedGeneration;
    final binding = DiskBinding(
      accountKey: account.key,
      generation: nextGeneration,
    );
    readCache.fenceOtherAccounts(
      binding,
      sessionOwner: this,
      accountKeys: _accounts.map((account) => account.key).toSet(),
    );
    readCache.retainDiskAccount(account.key, sessionOwner: this);
    _closeClient(api);
    active = account;
    api = client;
    generation = nextGeneration;
    client.bindReadCache(account.key, generation);
    readCache.bindOfflineRepository(client, binding);
    client.attachReadCacheDiskBackend(
      CoordinatedReadCacheDiskBackend(coordinator: readCache, binding: binding),
    );
    _publishReadCacheDecision(account.key, signOutPending: false);
    unawaited(_activateReadCache(binding));
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
  Future<bool> _commitSignOut({
    String? resumeAccountKey,
    String? retainedAccountKey,
  }) async {
    final ticket = _operation;
    final decision = _readCacheStartupDecision;
    final pendingResumeKey =
        decision != null && decision.readable && !decision.signOutPending
        ? decision.resumeAccountKey
        : null;
    _invalidateReadCacheDecision();
    final previousKey =
        active?.key ??
        offline?.account.key ??
        resumingAccount?.key ??
        readCache.diskRetainedAccountKey ??
        retainedAccountKey ??
        pendingResumeKey;
    if (previousKey != null) {
      unawaited(
        _clearReadCache(
          DiskBinding(accountKey: previousKey, generation: generation),
          ReadCacheCleanupOperation.signOut,
        ),
      );
    }
    readCache.retainDiskAccount(null, sessionOwner: this);
    _closeClient(_pending);
    _pending = null;
    _closeClient(api);
    api = null;
    active = null;
    offline = null;
    _offlineEligibility = null;
    offlineGate.stop();
    resuming = false;
    resumingAccount = null;
    initializing = false;
    _advanceGeneration();
    pendingSignOutCleanup = true;
    _emit();
    try {
      await _enqueueLastActive(null, signOut: true);
      if (_current(ticket)) {
        _publishReadCacheDecision(
          resumeAccountKey,
          signOutPending: pendingSignOutCleanup || resumeAccountKey == null,
        );
        _emit();
      }
      return true;
    } catch (_) {
      pendingSignOutCleanup = true;
      if (_current(ticket)) {
        _publishReadCacheDecision(null, signOutPending: true);
        _emit();
      }
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
    if (_disposed || !readCache.ownsStartupSession(this)) return;
    final ticket = ++_operation;
    busy = false;
    final cleared = await _commitSignOut();
    if (!_current(ticket) || cleared) return;
    message = l10n.cannotClearAutoSignIn;
    _emit();
  }

  Future<({bool removed, ApiFailure? failure})> remove(Account account) async {
    if (offline != null ||
        busy ||
        initializing ||
        resuming ||
        _disposed ||
        !readCache.ownsStartupSession(this)) {
      return (removed: false, failure: null);
    }
    final ticket = ++_operation;
    _invalidateReadCacheDecision();
    busy = true;
    message = null;
    untrusted = null;
    _refusedInstanceKey = null;
    _emit();
    final previous = List<Account>.of(_accounts);
    final staged = _accounts.where((item) => item.key != account.key).toList();
    _setAccounts(staged);
    final releaseMedia = suspendMarkdownMediaAccount(account);
    var removalCommitted = false;
    try {
      // Cleanup again inside the commit fence: a retained card may have started
      // after the shell's earlier file cleanup while other stores were cleared.
      await clearAccountArtifacts(account);
      if (!_current(ticket)) {
        if (identical(_accounts, staged)) {
          final decision = _readCacheStartupDecision;
          final restoreDecision =
              decision != null && isReadCacheDecisionCurrent(decision);
          _setAccounts(previous);
          if (restoreDecision) {
            _publishReadCacheDecision(
              decision.resumeAccountKey,
              signOutPending: decision.signOutPending,
            );
          }
        }
        return (removed: false, failure: null);
      }
      final binding = DiskBinding(
        accountKey: account.key,
        generation: generation,
      );
      ApiFailure? cacheFailure;
      final cacheClear = await _clearReadCache(
        binding,
        ReadCacheCleanupOperation.accountRemoval,
        onFailure: (failure) => cacheFailure = failure,
      );
      if (!cacheClear.keyGoneConfirmed && !cacheClear.directoryGoneConfirmed) {
        throw cacheFailure ??
            ApiFailure.readCacheCleanup(
              ReadCacheCleanupState(
                operation: ReadCacheCleanupOperation.accountRemoval,
                disposition: ReadCacheCleanupDisposition.accountRetained,
                code: ReadCacheCleanupCode.cleanupFailed,
                clearResult: cacheClear,
              ),
            );
      }
      var instanceStillSaved = true;
      await _enqueueAccountSave(
        onSaved: (saved) {
          // A superseding sign-out changes UI ownership, not a confirmed save.
          if (!saved.any((item) => item.key == account.key)) {
            removalCommitted = true;
            instanceStillSaved = saved.any(
              (item) => item.instance.key == account.instance.key,
            );
            markMarkdownMediaAccountRemoved(account);
            readCache.finishAccountRemoval(account.key, removed: true);
            if (_current(ticket) &&
                readCache.diskRetainedAccountKey == account.key) {
              readCache.retainDiskAccount(null, sessionOwner: this);
            }
          }
        },
      );
      // The CA is shared by every account of the instance, so it goes only
      // once the last one is confirmed removed. A failure leaves it for the
      // start-up sweep; the removal itself has succeeded.
      if (removalCommitted &&
          !instanceStillSaved &&
          !_accounts.any(
            (item) => item.instance.key == account.instance.key,
          )) {
        try {
          await trust.remove(account.instance).timeout(
            const Duration(seconds: 5),
          );
        } on Object {
          // Swept at the next start; this run already stopped trusting it.
        }
      }
      if (!_current(ticket)) return (removed: removalCommitted, failure: null);
      if (active?.key == account.key) {
        _pendingResumeTarget = null;
        final cleared = await _commitSignOut();
        if (_current(ticket) && !cleared) {
          message = l10n.cannotClearAutoSignIn;
        }
      }
    } catch (error) {
      if (_current(ticket) && identical(_accounts, staged)) {
        _setAccounts(previous);
      }
      if (_current(ticket)) message = l10n.removeSecureStorageFailed;
      readCache.finishAccountRemoval(account.key, removed: removalCommitted);
      if (error is ApiFailure && error.kind == FailureKind.readCacheCleanup) {
        return (removed: removalCommitted, failure: error);
      }
    } finally {
      releaseMedia();
      if (_current(ticket)) busy = false;
      if (_current(ticket) && _readCacheStartupDecision == null) {
        _publishReadCacheDecision(active?.key);
      }
      _emit();
    }
    return (removed: removalCommitted, failure: null);
  }

  @override
  void dispose() {
    final leaving = offline;
    if (leaving != null) {
      readCache.closeOfflineReadOnly(
        DiskBinding(
          accountKey: leaving.account.key,
          generation: leaving.generation,
        ),
        sessionOwner: this,
      );
    }
    _disposed = true;
    _operation++;
    _invalidateReadCacheDecision();
    _disposal.complete();
    offlineGate.dispose();
    _closeClient(_pending);
    _closeClient(api);
    readCache.releaseSession(this);
    _pendingResumeTarget = null;
    super.dispose();
  }
}
