import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/instance.dart';
import '../../shared/workspace_ui.dart';
import '../workspace/editor.dart';
import 'session_controller.dart';

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
  @override
  void initState() {
    super.initState();
    _instance.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _instance.dispose();
    _token.dispose();
    super.dispose();
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
    if (widget.session.busy || _form.currentState?.validate() != true) {
      return;
    }
    FocusScope.of(context).unfocus();
    await widget.session.connect(_instance.text, _token.text);
    if (mounted && widget.session.active != null) {
      _token.clear();
    }
  }

  Future<void> _connectOAuth() async {
    if (widget.session.busy || _oauthApplicationId == null) {
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
                          'GitLab，\n隨手掌握。',
                          style: theme.textTheme.headlineLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '專案、程式碼、審查與 CI。\n為手機重新整理的工作空間。',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (session.accounts.isNotEmpty) ...[
                          const SizedBox(height: 28),
                          Text('繼續使用', style: theme.textTheme.titleSmall),
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
                                    '@${account.user.username}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(account.instance.base.host),
                                  onTap: session.busy
                                      ? null
                                      : () {
                                          unawaited(session.select(account));
                                        },
                                  trailing: IconButton(
                                    key: Key('removeAccount-${account.key}'),
                                    tooltip: '從此裝置移除帳號',
                                    icon: const Icon(Icons.logout, size: 20),
                                    onPressed: session.busy
                                        ? null
                                        : () async {
                                            if (!await confirmAction(
                                              context,
                                              '移除此帳號？',
                                              '會清除這個帳號在此裝置的登入與草稿，不會撤銷 GitLab 上的 Token。',
                                            )) {
                                              return;
                                            }
                                            if (!context.mounted) {
                                              return;
                                            }
                                            await clearSecureDrafts(account);
                                            await session.remove(account);
                                          },
                                  ),
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 28),
                        Text('連接帳號', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('instanceField'),
                          controller: _instance,
                          enabled: !session.busy,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'GitLab 網址',
                            prefixIcon: Icon(Icons.public),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '請輸入實例網址'
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
                              tooltip: _obscure ? '顯示 Token' : '隱藏 Token',
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
                              ? '請輸入 Token'
                              : null,
                          onFieldSubmitted: (_) {
                            unawaited(_connect());
                          },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '協作操作需要 api 權限；僅閱讀可使用 read_api。',
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
                          onPressed: session.busy
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
                          label: Text(session.busy ? '正在確認帳號…' : '驗證並連接'),
                        ),
                        if (_oauthApplicationId != null &&
                            _oauthApplicationId!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const Key('oauthButton'),
                            onPressed: session.busy
                                ? null
                                : () {
                                    unawaited(_connectOAuth());
                                  },
                            icon: const Icon(Icons.open_in_browser, size: 20),
                            label: const Text('透過 GitLab 授權登入'),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          'Token 僅傳送到上方的 GitLab 實例，並保存在裝置安全儲存。請勿輸入帳號密碼。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          '獨立第三方客戶端 · 非 GitLab 官方產品',
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
