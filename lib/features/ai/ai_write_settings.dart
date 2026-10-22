import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../security/app_lock.dart';
import 'ai_stores.dart';

/// The name of an autonomy level, as the settings and the chat show it.
String aiLevelLabel(AiAutonomyLevel level) => switch (level) {
  AiAutonomyLevel.readOnly => l10n.aiLevelReadOnly,
  AiAutonomyLevel.confirmEach => l10n.aiLevelConfirmEach,
  AiAutonomyLevel.lowRiskAuto => l10n.aiLevelLowRiskAuto,
  AiAutonomyLevel.conversationGrant => l10n.aiLevelConversationGrant,
  AiAutonomyLevel.bypass => l10n.aiLevelBypass,
};

/// What a level lets the AI do on its own (plan v6 §4.1).
String aiLevelHint(AiAutonomyLevel level) => switch (level) {
  AiAutonomyLevel.readOnly => l10n.aiLevelReadOnlyHint,
  AiAutonomyLevel.confirmEach => l10n.aiLevelConfirmEachHint,
  AiAutonomyLevel.lowRiskAuto => l10n.aiLevelLowRiskAutoHint,
  AiAutonomyLevel.conversationGrant => l10n.aiLevelConversationGrantHint,
  AiAutonomyLevel.bypass => l10n.aiLevelBypassHint,
};

/// "AI writes" in the AI settings of one account: the highest level, the
/// level new conversations start at, and the AI attribution footer.
class AiWriteSettingsSection extends StatelessWidget {
  const AiWriteSettingsSection({
    super.key,
    required this.record,
    required this.enabled,
    required this.onCeiling,
    required this.onStartingLevel,
    required this.onAttribution,
  });

  final AiAccountRecord record;
  final bool enabled;
  final ValueChanged<AiAutonomyLevel> onCeiling;
  final ValueChanged<AiAutonomyLevel> onStartingLevel;
  final ValueChanged<bool> onAttribution;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // A conversation grant is chosen in a conversation, never as a start.
    final starts = [
      for (final level in AiAutonomyLevel.values)
        if (level.index <= record.ceiling.index &&
            level != AiAutonomyLevel.conversationGrant)
          level,
    ];
    return HubSection(
      title: l10n.aiWriteSettingsTitle,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(l10n.aiWriteSettingsIntro, style: muted),
        ),
        ListTile(
          key: const ValueKey('ai-write-ceiling'),
          enabled: enabled,
          leading: const Icon(Icons.vertical_align_top),
          title: Text(l10n.aiWriteCeiling),
          subtitle: Text(
            '${aiLevelLabel(record.ceiling)}\n${l10n.aiWriteCeilingHint}',
          ),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showAiLevelPicker(
              context,
              title: l10n.aiWriteCeiling,
              current: record.ceiling,
              options: AiAutonomyLevel.values,
            );
            if (picked != null && picked != record.ceiling) onCeiling(picked);
          },
        ),
        ListTile(
          key: const ValueKey('ai-write-starting'),
          enabled: enabled,
          leading: const Icon(Icons.play_circle_outline),
          title: Text(l10n.aiWriteStartingLevel),
          subtitle: Text(aiLevelLabel(record.startingLevel)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final picked = await showAiLevelPicker(
              context,
              title: l10n.aiWriteStartingLevel,
              current: record.startingLevel,
              options: starts,
            );
            if (picked != null && picked != record.startingLevel) {
              onStartingLevel(picked);
            }
          },
        ),
        SwitchListTile(
          key: const ValueKey('ai-write-attribution'),
          secondary: const Icon(Icons.auto_awesome_outlined),
          title: Text(l10n.aiWriteAttribution),
          subtitle: Text(l10n.aiWriteAttributionHint),
          value: record.aiAttribution,
          onChanged: enabled ? onAttribution : null,
        ),
      ],
    );
  }
}

/// A bottom sheet listing [options] with what each lets the AI do.
Future<AiAutonomyLevel?> showAiLevelPicker(
  BuildContext context, {
  required String title,
  required AiAutonomyLevel current,
  required List<AiAutonomyLevel> options,
}) => showModalBottomSheet<AiAutonomyLevel>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          RadioGroup<AiAutonomyLevel>(
            groupValue: current,
            onChanged: (level) => Navigator.of(context).pop(level),
            child: Column(
              children: [
                for (final level in options)
                  RadioListTile<AiAutonomyLevel>(
                    key: ValueKey('ai-level-${level.name}'),
                    contentPadding: EdgeInsets.zero,
                    value: level,
                    title: Text(aiLevelLabel(level)),
                    subtitle: Text(aiLevelHint(level)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  },
);

/// Turning on "allow everything" (plan v6 §4.2): only here, in the
/// foreground, for this exact account, after typing the username and passing
/// the device check that guards the app lock. Returns whether it may be
/// turned on.
Future<bool> confirmAiBypass(
  BuildContext context, {
  required Account account,
  required AppLockAuthenticator deviceCheck,
}) async {
  final confirmed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          _BypassConfirmPage(account: account, deviceCheck: deviceCheck),
    ),
  );
  return confirmed ?? false;
}

class _BypassConfirmPage extends StatefulWidget {
  const _BypassConfirmPage({required this.account, required this.deviceCheck});

  final Account account;
  final AppLockAuthenticator deviceCheck;

  @override
  State<_BypassConfirmPage> createState() => _BypassConfirmPageState();
}

class _BypassConfirmPageState extends State<_BypassConfirmPage> {
  final _username = TextEditingController();
  bool? _available;
  var _checking = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _username.addListener(() => setState(() {}));
    widget.deviceCheck.available().then(
      (available) {
        if (mounted) setState(() => _available = available);
      },
      onError: (Object _) {
        if (mounted) setState(() => _available = false);
      },
    );
  }

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  bool get _typed {
    final typed = _username.text.trim();
    final name = widget.account.user.username;
    return typed == '@$name' || typed == name;
  }

  Future<void> _confirm() async {
    setState(() {
      _checking = true;
      _failed = false;
    });
    var passed = false;
    try {
      passed = await widget.deviceCheck.authenticate(l10n.aiBypassReason);
    } on Object {
      passed = false;
    }
    if (!mounted) return;
    if (passed) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _checking = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = widget.account;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final unavailable = _available == false;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiBypassTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: HubColors.orange,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.aiBypassWarning,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.aiBypassAccount, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            // The full instance, the account and its numeric ID: the user
            // must see exactly which account this is for.
            Text(
              account.instance.base.toString(),
              key: const ValueKey('ai-bypass-instance'),
              style: muted,
            ),
            Text(
              '${isolated(account.user.name)} · '
              '${isolated('@${account.user.username}')} · '
              '${l10n.aiBypassUserId('${account.user.id}')}',
              key: const ValueKey('ai-bypass-account'),
              style: muted,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('ai-bypass-username'),
              controller: _username,
              enabled: !unavailable && !_checking,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.aiBypassTypeUsername(
                  '@${account.user.username}',
                ),
              ),
            ),
            if (unavailable) ...[
              const SizedBox(height: 12),
              Text(
                l10n.aiBypassNoDeviceLock,
                key: const ValueKey('ai-bypass-unavailable'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_failed) ...[
              const SizedBox(height: 12),
              Text(
                l10n.aiBypassCheckFailed,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                key: const ValueKey('ai-bypass-confirm'),
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.fingerprint),
                label: Text(l10n.aiBypassConfirm),
                onPressed: _available == true && _typed && !_checking
                    ? _confirm
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
