import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import '../ai/ai_account_removal.dart';
import '../ai/ai_write_journal.dart';
import 'session_controller.dart';

import '../../l10n/l10n.dart';
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session});
  final SessionController session;
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

  @override
  void initState() {
    super.initState();
    _instance.addListener(() {
      if (mounted) setState(() {});
    });
    AiAccountRemoval.changes.addListener(_onRemovalChanged);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showLeftRemovalResults(),
    );
  }

  @override
  void dispose() {
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

  /// §8 account removal: the hold is taken here, synchronously, before any
  /// dialog. No account is signed in, so there is no run to stop.
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
    FocusScope.of(context).unfocus();
    await widget.session.connectOAuth(_instance.text);
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
                                          unawaited(session.select(account));
                                        },
                                  trailing: IconButton(
                                    key: Key('removeAccount-${account.key}'),
                                    tooltip: l10n.removeAccountFromDevice,
                                    icon: const Icon(Icons.logout, size: 20),
                                    onPressed: locked
                                        ? null
                                        : () => _remove(account),
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
