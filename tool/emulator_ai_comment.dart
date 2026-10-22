import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'emulator_ui.dart';

const _enabled = bool.fromEnvironment('EMULATOR_UI_QA');
const _resource = 'projects/42/merge_requests/12/root/new';
const _existingDraft = 'Existing reviewer note';
const _answer =
    'Synthetic **AI answer**\n\nPlease verify this text before sending.';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_enabled) {
    throw StateError(
      'AI comment QA requires --dart-define=EMULATOR_UI_QA=true.',
    );
  }
  useLanguage(languageForTag('zh-TW')!);
  final fixture = EmulatorQaFixture();
  // The guarded QA target uses memory-only storage so it cannot overwrite a
  // developer's real encrypted drafts on the project emulator.
  // ignore: invalid_use_of_visible_for_testing_member
  FlutterSecureStorage.setMockInitialValues({
    _draftKey(fixture.account.key, _resource): jsonEncode({
      'body': _existingDraft,
    }),
  });
  runApp(_AiCommentQaApp(fixture: fixture));
}

String _draftKey(String accountKey, String resource) =>
    'draft.v2.${base64Url.encode(utf8.encode(accountKey))}.'
    '${base64Url.encode(utf8.encode(resource))}';

final class _QaSession extends ChangeNotifier implements AiChatSession {
  _QaSession(this.origin);

  @override
  final AiChatOrigin origin;

  @override
  String get id => origin.key;

  @override
  List<AiChatItem> get items => const [
    AiAssistantItem(text: _answer, state: AiAssistantState.done),
  ];

  @override
  AiChatPhase get phase => AiChatPhase.idle;

  @override
  AiChatBlocker get blocker => AiChatBlocker.noProvider;

  @override
  List<AiProviderConfig> get providers => const [];

  @override
  AiProviderConfig? get provider => null;

  @override
  AiConsentContract? get consentRequest => null;

  @override
  AiFailure? get failure => null;

  @override
  AiRunEnd? get lastEnd => null;

  @override
  bool get offerNewConversation => false;

  @override
  bool get historySaved => false;

  @override
  bool get canSend => false;

  @override
  Future<void> send(String text) async {}

  @override
  void stop() {}

  @override
  void startNewConversation() {}

  @override
  Future<void> useProvider(String providerId) async {}

  @override
  Future<void> recheck() async {}

  @override
  set confirmCleartext(Future<bool> Function()? callback) {}

  @override
  String displaySafe(String text) => text;
}

final class _QaRegistry extends ChangeNotifier implements AiRunRegistry {
  _QaSession? _session;

  @override
  AiChatSession open(AiChatOrigin origin) => _session ??= _QaSession(origin);

  @override
  void release(AiChatSession session) {}

  @override
  int get runningCount => 0;

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }
}

final class _AiCommentQaApp extends StatefulWidget {
  const _AiCommentQaApp({required this.fixture});

  final EmulatorQaFixture fixture;

  @override
  State<_AiCommentQaApp> createState() => _AiCommentQaAppState();
}

final class _AiCommentQaAppState extends State<_AiCommentQaApp> {
  late final EmulatorQaMemoryAccountStore _accountStore;
  late final SessionController _session;
  late final MemoryAiStore _aiStore;
  late final AiSettingsController _settings;
  late final AiHistoryCoordinator _history;
  late final _QaRegistry _registry;

  @override
  void initState() {
    super.initState();
    final fixture = widget.fixture;
    _accountStore = EmulatorQaMemoryAccountStore()
      ..accounts = [fixture.account]
      ..lastActive = fixture.account.key;
    _session = SessionController(_accountStore)
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    _aiStore = MemoryAiStore();
    _settings = AiSettingsController(_aiStore);
    _history = AiHistoryCoordinator(store: _aiStore);
    _registry = _QaRegistry();
    unawaited(_settings.initialize());
  }

  @override
  void dispose() {
    _registry.dispose();
    _history.dispose();
    _settings.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fixture = widget.fixture;
    return ProviderScope(
      overrides: [sessionProvider.overrideWithValue(_session)],
      child: AiScope(
        controllers: AiControllers(settings: _settings, history: _history),
        accountKey: fixture.account.key,
        child: AiRunRegistryScope(
          registry: _registry,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(Brightness.light),
            locale: const Locale('zh', 'TW'),
            supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => Column(
              children: [
                _QaBanner(fixture: fixture),
                Expanded(child: child ?? const SizedBox.shrink()),
              ],
            ),
            home: WorkItemPage(
              account: fixture.account,
              api: fixture.api,
              project: fixture.project,
              resource: 'merge_requests',
              iid: 12,
            ),
          ),
        ),
      ),
    );
  }
}

final class _QaBanner extends StatefulWidget {
  const _QaBanner({required this.fixture});

  final EmulatorQaFixture fixture;

  @override
  State<_QaBanner> createState() => _QaBannerState();
}

final class _QaBannerState extends State<_QaBanner> {
  late final Timer _timer;

  int get _writes => widget.fixture.adapter.requests
      .where((request) => request.method != 'GET' && request.method != 'HEAD')
      .length;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final writes = _writes;
    return Material(
      color: writes == 0 ? const Color(0xff164e3f) : const Color(0xff8a4b08),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(
            'SYNTHETIC AI COMMENT QA  •  network writes: $writes\n'
            '更多選項 → 與 AI 討論 → 附加到留言草稿（預期仍為 0）',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }
}
