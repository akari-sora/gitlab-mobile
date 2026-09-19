import 'dart:async';
import 'package:flutter/material.dart';
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
  void dispose() { _instance.dispose(); _token.dispose(); super.dispose(); }
  Future<void> _connect() async {
    if (_form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    await widget.session.connect(_instance.text, _token.text);
    if (mounted && widget.session.active != null) _token.clear();
  }
  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Scaffold(
      appBar: AppBar(title: const Text('GitLab Mobile')),
      body: SafeArea(child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: AutofillGroup(child: Form(
          key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('把專案帶在身上', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            const Text('原生手機工作介面。登入後先核對 App 身分，再開啟私有專案。'),
            const SizedBox(height: 20),
            const Card(child: Padding(padding: EdgeInsets.all(12), child: Text('開發預覽 · 唯讀 PAT 流程'))),
            if (session.accounts.isNotEmpty) ...[
              const SizedBox(height: 16), const Text('已儲存的帳號'),
              ...session.accounts.map((account) => Card(child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('@${account.user.username}'), subtitle: Text(account.instance.key),
                onTap: session.busy ? null : () { unawaited(session.select(account)); },
                trailing: const Icon(Icons.chevron_right),
              ))),
              const Divider(height: 32),
            ],
            TextFormField(key: const Key('instanceField'), controller: _instance,
              enabled: !session.busy, keyboardType: TextInputType.url,
              autocorrect: false, enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'GitLab 實例',
                helperText: '支援 HTTPS 自架網址與安裝子路徑'),
              validator: (value) => value == null || value.trim().isEmpty ? '請輸入實例網址' : null,
            ),
            const SizedBox(height: 20),
            TextFormField(key: const Key('tokenField'), controller: _token,
              enabled: !session.busy, obscureText: _obscure,
              autocorrect: false, enableSuggestions: false,
              autofillHints: const [],
              smartDashesType: SmartDashesType.disabled, smartQuotesType: SmartQuotesType.disabled,
              decoration: InputDecoration(labelText: 'Personal Access Token',
                helperText: '建議 read_api；不要輸入 GitLab 密碼。',
                suffixIcon: IconButton(tooltip: _obscure ? '顯示 Token' : '隱藏 Token',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure)),
              ),
              validator: (value) => value == null || value.trim().isEmpty ? '請輸入 Token' : null,
              onFieldSubmitted: (_) { if (!session.busy) unawaited(_connect()); },
            ),
            const SizedBox(height: 16),
            const Text('Token 僅送至你輸入的 GitLab 實例。存入裝置安全儲存；不儲存私有程式碼到磁碟。'),
            if (session.message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
              child: Semantics(liveRegion: true, child: Text(session.message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)))),
            const SizedBox(height: 20),
            FilledButton.icon(key: const Key('connectButton'),
              onPressed: session.busy ? null : () { unawaited(_connect()); },
              icon: session.busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login),
              label: Text(session.busy ? '核對帳號與安全儲存…' : '驗證並連接'),
            ),
            const SizedBox(height: 24),
            const Text('OAuth PKCE、協作寫入與推播尚未啟用。本預覽不宣稱已通過真機或登入整合驗收。'),
          ]),
        ))),
      ))),
    );
  }
}
