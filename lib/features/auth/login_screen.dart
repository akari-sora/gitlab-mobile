import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../shared/workspace_ui.dart';
import '../ai/ai_account_removal.dart';
import '../ai/ai_write_journal.dart';
import '../offline/offline_app.dart';
import 'session_controller.dart';

import '../../l10n/l10n.dart';
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session, this.onTryDemo});
  final SessionController session;

  /// Opens the built-in demo; the action is hidden when null. A failure is
  /// shown here like any other.
  final Future<void> Function()? onTryDemo;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _instance = TextEditingController(text: 'https://gitlab.com');
  final _token = TextEditingController();
  bool _obscure = true;

  /// The removal job this page started, from the hold until it ends (§8).
  AiRemovalJob? _removal;

  /// The account whose removal waits for writes in flight.
  String? _removalWaiting;

  /// Arms dispose: a page that goes away requests cancellation of its job.
  VoidCallback? _cancelOnDispose;
  AiAccountDialogs? _ownDialogs;
  AiAccountDialogs get _dialogs => _ownDialogs ??= AiAccountDialogs(context);

  /// Cancels the read-cache notice subscription.
  void Function()? _cancelReadCacheNotices;
  bool _retryingCleanup = false;

  @override
  void initState() {
    super.initState();
    _instance.addListener(() {
      if (mounted) setState(() {});
    });
    // A sign-out cleanup can fail while no page is listening; the snapshot
    // read in build still shows it, and later notices rebuild this page.
    _cancelReadCacheNotices = widget.session.readCache.subscribe((_) {
      // The notice can arrive while the app is idle: ask for the frame too.
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (mounted) setState(() {});
        })
        ..ensureVisualUpdate();
    });
    AiAccountRemoval.changes.addListener(_onRemovalChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showLeftRemovalResults(),
    );
  }

  @override
  void dispose() {
    _cancelReadCacheNotices?.call();
    _cancelReadCacheNotices = null;
    AiAccountRemoval.changes.removeListener(_onRemovalChanged);
    // Signing in replaces this page and its Navigator. Before the final
    // confirmation that stops the job; after it, the job runs to its end.
    _cancelOnDispose?.call();
    _cancelOnDispose = null;
    _ownDialogs?.close();
    _instance.dispose();
    _token.dispose();
    super.dispose();
  }

  void _onRemovalChanged() {
    if (!mounted) return;
    setState(() {});
    if (_removal == null) _showLeftRemovalResults();
  }

  /// Results of removal jobs whose page went away (§8 step 5).
  void _showLeftRemovalResults() {
    if (!mounted || _removal != null) return;
    for (final saved in widget.session.accounts) {
      final result = AiAccountRemoval.takeResult(saved.key);
      if (result != null) presentAiRemovalResult(context, result);
    }
  }

  /// The account whose disk data this device kept after a failed resume or
  /// same-account retry (B8/B10): it is the one that loses its offline
  /// projects when the sign-in screen moves on to another account (§6.7).
  /// The same source as `select`, including before startup recovery ran.
  String? get _retainedKey {
    final key = widget.session.leavingDiskAccountKey;
    if (key == null) return null;
    return widget.session.accounts.any((account) => account.key == key)
        ? key
        : null;
  }

  /// §6.7 before anything changes: true when the user goes on.
  Future<bool> _confirmLeavingRetained(RetainedLeave kind) async {
    final retained = _retainedKey;
    if (retained == null) return true;
    final confirmed = await confirmRetainedOfflineLoss(
      context,
      widget.session,
      accountKey: retained,
      kind: kind,
    );
    return confirmed && mounted;
  }

  /// Picking the retained account itself is the same-account retry (B8) and
  /// asks nothing; any other account first confirms the retained one's loss.
  Future<void> _select(Account account) async {
    final session = widget.session;
    if (session.busy || AiAccountRemoval.anyRunning) return;
    if (account.key != _retainedKey &&
        !await _confirmLeavingRetained(RetainedLeave.switchAccount)) {
      return;
    }
    if (session.busy || AiAccountRemoval.anyRunning) return;
    await session.select(account);
  }

  /// Removing the retained account confirms its offline projects first, then
  /// §8 account removal runs.
  Future<void> _confirmRemove(Account account) async {
    if (AiAccountRemoval.anyRunning || widget.session.busy) return;
    if (account.key == _retainedKey &&
        !await _confirmLeavingRetained(RetainedLeave.remove)) {
      return;
    }
    if (mounted) _remove(account);
  }

  /// §8 account removal: the hold is taken here, synchronously, before the
  /// removal's own dialogs. No account is signed in, so there is no run to
  /// stop.
  void _remove(Account account) {
    if (AiAccountRemoval.anyRunning || widget.session.busy) return;
    final job = AiAccountRemoval.begin(account.key);
    if (job == null) return;
    setState(() => _removal = job);
    unawaited(_runRemoval(account, job));
  }

  Future<void> _runRemoval(Account account, AiRemovalJob job) async {
    await AiAccountRemoval.run(
      account: account,
      job: job,
      session: widget.session,
      clearReadCacheDisk: (saved) =>
          widget.session.readCache.clearReadCacheDisk(saved.key),
      confirm: (prompt) => _dialogs.confirmRemoval(account, prompt),
      waitForInFlightWrites: () async {},
      requestCancelOnDispose: () => _cancelOnDispose = job.requestCancel,
      onWaiting: (waiting) {
        if (mounted) {
          setState(() => _removalWaiting = waiting ? account.key : null);
        }
      },
    );
    _cancelOnDispose = null;
    if (!mounted) return;
    setState(() {
      _removal = null;
      _removalWaiting = null;
    });
    final result = AiAccountRemoval.takeResult(account.key);
    if (result != null) presentAiRemovalResult(context, result);
  }

  /// Retries only the signed-out cleanups. A signed-out retry never activates
  /// a session or reopens the disk, whatever its result.
  Future<void> _retrySignedOutCleanup() async {
    if (_retryingCleanup) return;
    final cache = widget.session.readCache;
    final pending = cache.signedOutSnapshot.keys.toList();
    if (pending.isEmpty) return;
    setState(() => _retryingCleanup = true);
    ApiFailure? failure;
    var complete = true;
    for (final binding in pending) {
      final result = await cache.retryCleanup(
        binding,
        ReadCacheCleanupOperation.signOut,
      );
      if (!result.complete) {
        complete = false;
        failure = cache.signedOutSnapshot[binding]?.failure ?? failure;
      }
    }
    if (!mounted) return;
    setState(() => _retryingCleanup = false);
    if (complete) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.offlineCacheCleared)),
      );
    } else if (failure != null) {
      showFailure(
        context,
        failure,
        onRetryCleanup: () => unawaited(_retrySignedOutCleanup()),
      );
    }
  }

  String? get _oauthApplicationId {
    try {
      return widget.session.applicationIdFor(
        GitLabInstance.parse(_instance.text),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _connect() async {
    if (widget.session.busy ||
        AiAccountRemoval.anyRunning ||
        _form.currentState?.validate() != true) {
      return;
    }
    if (!await _confirmLeavingRetained(RetainedLeave.connect) ||
        !mounted ||
        widget.session.busy ||
        AiAccountRemoval.anyRunning) {
      return;
    }
    FocusScope.of(context).unfocus();
    await widget.session.connect(_instance.text, _token.text);
    if (mounted && widget.session.active != null) {
      _token.clear();
    }
  }

  Future<void> _connectOAuth() async {
    if (widget.session.busy ||
        AiAccountRemoval.anyRunning ||
        _oauthApplicationId == null) {
      return;
    }
    if (!await _confirmLeavingRetained(RetainedLeave.connect) ||
        !mounted ||
        widget.session.busy ||
        AiAccountRemoval.anyRunning) {
      return;
    }
    FocusScope.of(context).unfocus();
    await widget.session.connectOAuth(_instance.text);
  }

  Future<void> _tryDemo() async {
    try {
      await widget.onTryDemo?.call();
    } on Object catch (error) {
      if (mounted) showFailure(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        // While a removal job holds its token, switching, removal and
        // signing in stay disabled.
        final locked = session.busy || AiAccountRemoval.anyRunning;
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              Icons.account_tree_outlined,
                              size: 32,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          l10n.gitlabAtYourFingertips,
                          style: theme.textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.projectsCodeReviewWorkspace,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        // Pending signed-out cleanups merge into one notice.
                        if (session.readCache.signedOutSnapshot.values
                            case Iterable<ReadCacheNotice>(isNotEmpty: true, :final last))
                          Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: FailureNotice(
                              key: const ValueKey('signed-out-cache-notice'),
                              last.failure,
                              onRetryCleanup: _retryingCleanup
                                  ? null
                                  : () => unawaited(_retrySignedOutCleanup()),
                            ),
                          ),
                        if (session.accounts.isNotEmpty) ...[
                          const SizedBox(height: 28),
                          Text(l10n.continueUsing, style: theme.textTheme.titleSmall),
                          const SizedBox(height: 12),
                          for (final account in session.accounts)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Card(
                                child: ListTile(
                                  leading: Monogram(
                                    account.user.name,
                                    size: 36,
                                  ),
                                  title: Text(
                                    isolated('@${account.user.username}'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    _removalWaiting == account.key
                                        ? l10n.aiRemoveWaitingWrites
                                        : account.instance.base.host,
                                  ),
                                  onTap: locked
                                      ? null
                                      : () {
                                          unawaited(_select(account));
                                        },
                                  trailing: IconButton(
                                    key: Key('removeAccount-${account.key}'),
                                    tooltip: l10n.removeAccountFromDevice,
                                    icon: const Icon(Icons.logout, size: 20),
                                    onPressed: locked
                                        ? null
                                        : () => unawaited(
                                            _confirmRemove(account),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 28),
                        Text(l10n.connectAccount, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('instanceField'),
                          controller: _instance,
                          enabled: !session.busy,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: l10n.gitlabUrl,
                            prefixIcon: Icon(Icons.public),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? l10n.enterInstanceUrl
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('tokenField'),
                          controller: _token,
                          enabled: !session.busy,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [],
                          smartDashesType: SmartDashesType.disabled,
                          smartQuotesType: SmartQuotesType.disabled,
                          decoration: InputDecoration(
                            labelText: 'Personal Access Token',
                            prefixIcon: const Icon(Icons.key_outlined),
                            suffixIcon: IconButton(
                              tooltip: _obscure ? l10n.showToken : l10n.hideToken,
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? l10n.enterToken
                              : null,
                          onFieldSubmitted: (_) {
                            unawaited(_connect());
                          },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.apiScopeForCollaboration,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (session.message != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                session.message!,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const Key('connectButton'),
                          onPressed: locked
                              ? null
                              : () {
                                  unawaited(_connect());
                                },
                          icon: session.busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_forward, size: 20),
                          label: Text(session.busy ? l10n.verifyingAccount : l10n.verifyAndConnect),
                        ),
                        if (_oauthApplicationId != null &&
                            _oauthApplicationId!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const Key('oauthButton'),
                            onPressed: locked
                                ? null
                                : () {
                                    unawaited(_connectOAuth());
                                  },
                            icon: const Icon(Icons.open_in_browser, size: 20),
                            label: Text(l10n.signInWithGitlabAuth),
                          ),
                        ],
                        if (widget.onTryDemo != null) ...[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            key: const Key('tryDemoButton'),
                            onPressed: locked ? null : () => unawaited(_tryDemo()),
                            icon: const Icon(Icons.science_outlined, size: 20),
                            label: Text(l10n.demoTryAction),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          l10n.tokenSentOnlyToInstance,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          l10n.thirdPartyNotOfficialProduct,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
