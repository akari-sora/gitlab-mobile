import 'package:flutter/material.dart';

import '../../core/ai/ai_provider.dart';
import '../../core/ai/tools/write_ledger.dart'
    show AiScopeClass, productionAiLedger;
import '../../l10n/l10n.dart';
import '../../shared/external_link.dart';
import '../demo/demo_scope.dart';
import 'ai_scope.dart';
import 'ai_settings_failure.dart';
import 'ai_stores.dart';
import 'ai_write_settings.dart';

/// The stable, non-secret disclosure saved with a granted consent.
Map<String, Object?> aiConsentSummary(
  AiConsentContract contract, {
  String? providerName,
  String? model,
}) {
  final categories = contract.dataCategories.toList()..sort();
  final policyUri = contract.policyUrl == null
      ? null
      : _safePolicyUri(contract.policyUrl!);
  final retentionDays = contract.retentionDays;
  return <String, Object?>{
    if (providerName != null && providerName.trim().isNotEmpty)
      'providerName': providerName.trim(),
    'origin': contract.origin,
    'format': contract.format.name,
    'cleartext': contract.cleartext,
    'toolsEnabled': contract.toolsEnabled,
    'dataCategories': categories,
    'policyIdentity': contract.policyIdentity,
    if (policyUri != null) 'policyUrl': policyUri.toString(),
    'retentionDays': ?retentionDays,
    'model': ?(contract.routedModel ?? model),
    'dataUse': contract.dataUse.name,
    'disclosureVersion': contract.disclosureVersion,
    'toolCatalogueVersion': contract.toolCatalogueVersion,
    'policyCheckedOn': ?contract.policyCheckedOn,
    'writePolicy': ?contract.writePolicy?.toCanonicalJson(),
  };
}

/// Shows the versioned disclosure and stores its hash and readable summary
/// only after the user explicitly agrees. Returns whether consent was granted.
/// [agreeLabel] replaces "Agree and send" when nothing is waiting to be sent.
Future<bool> showAiConsentDialog(
  BuildContext context,
  AiSettingsController settings,
  String accountKey,
  AiConsentContract requestedContract, {
  bool readOnly = false,
  String? agreeLabel,
}) async {
  final provider = settings.providers
      .where((candidate) => candidate.id == requestedContract.providerId)
      .firstOrNull;
  if (provider == null) return false;
  AiConsentContract contract;
  try {
    // Rebuilt from the provider as it is now, with the write policy the
    // conversation asked for: a provider edited meanwhile changes the hash.
    contract = aiConsentContractFor(
      provider,
      toolCatalogueVersion: requestedContract.toolCatalogueVersion,
      disclosureVersion: requestedContract.disclosureVersion,
      dataCategories: requestedContract.dataCategories,
      writePolicy: requestedContract.writePolicy,
    );
  } on Object {
    return false;
  }
  if (contract.hash != requestedContract.hash) return false;
  final capturedRecipientRevision = provider.recipientRevision;
  final initialScope = AiScope.maybeOf(context);
  if (initialScope != null && initialScope.accountKey != accountKey) {
    return false;
  }
  final requireScopeBinding = initialScope != null;
  bool isCurrent() {
    final current = settings.providers
        .where((candidate) => candidate.id == contract.providerId)
        .firstOrNull;
    if (current?.recipientRevision != capturedRecipientRevision) return false;
    if (requireScopeBinding) {
      return context.mounted &&
          AiScope.maybeOf(context)?.accountKey == accountKey;
    }
    return true;
  }

  final summary = aiConsentSummary(
    contract,
    providerName: provider.name,
    model: provider.model,
  );
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (dialogContext) => Dialog.fullscreen(
      child: ScaffoldMessenger(
        child: _AiConsentPage(
          details: _ConsentDetails.fromSummary(summary),
          readOnly: readOnly,
          agreeLabel: agreeLabel,
          onAgree: readOnly
              ? null
              : (failureContext) async {
                  if (!isCurrent()) {
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop(false);
                    }
                    return;
                  }
                  try {
                    final grantedAt = DateTime.now().toUtc();
                    await settings.grantConsent(
                      accountKey,
                      contract,
                      summary,
                      grantedAt: grantedAt,
                      expectedRecipientRevision: capturedRecipientRevision,
                    );
                    if (!isCurrent()) {
                      await settings.revokeConsent(
                        accountKey,
                        contract.providerId,
                        onlyIf: AiConsentRecord(
                          hash: contract.hash,
                          summary: summary,
                          grantedAt: grantedAt,
                        ),
                      );
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop(false);
                      }
                      return;
                    }
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop(true);
                    }
                  } on Object catch (error) {
                    if (dialogContext.mounted) {
                      showAiSettingsFailure(failureContext, error);
                    }
                  }
                },
        ),
      ),
    ),
  );
  return result ?? false;
}

/// Shows the exact readable disclosure saved when consent was granted.
Future<void> showAiConsentRecordDialog(
  BuildContext context,
  AiConsentRecord record,
) async {
  await showDialog<void>(
    context: context,
    useSafeArea: false,
    builder: (dialogContext) => Dialog.fullscreen(
      child: _AiConsentPage(
        details: _ConsentDetails.fromSummary(
          record.summary,
          grantedAt: record.grantedAt,
        ),
        readOnly: true,
      ),
    ),
  );
}

class _AiConsentPage extends StatefulWidget {
  const _AiConsentPage({
    required this.details,
    required this.readOnly,
    this.agreeLabel,
    this.onAgree,
  });

  final _ConsentDetails details;
  final bool readOnly;
  final String? agreeLabel;
  final Future<void> Function(BuildContext)? onAgree;

  @override
  State<_AiConsentPage> createState() => _AiConsentPageState();
}

class _AiConsentPageState extends State<_AiConsentPage> {
  var _saving = false;

  Future<void> _agree() async {
    if (_saving || widget.onAgree == null) return;
    setState(() => _saving = true);
    await widget.onAgree!(context);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final details = widget.details;
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(
            widget.readOnly ? l10n.aiConsentDetailsTitle : l10n.aiConsentTitle,
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  // The demo's provider is a script on the device: the
                  // recipient below never receives the conversation.
                  if (DemoScope.maybeOf(context) != null)
                    _InfoCard(
                      key: const ValueKey('ai-consent-demo'),
                      icon: Icons.science_outlined,
                      title: l10n.demoBanner,
                      children: [Text(l10n.demoConsentNotice)],
                    ),
                  if (details.grantedAt != null)
                    _InfoCard(
                      icon: Icons.history,
                      title: l10n.aiConsentGrantedAtHeading,
                      children: [
                        Text(_dateTime(context, details.grantedAt!)),
                        const SizedBox(height: 4),
                        Text(
                          l10n.aiConsentSavedSummaryNotice,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  _InfoCard(
                    icon: Icons.outbox_outlined,
                    title: l10n.aiConsentRecipientHeading,
                    children: [
                      if (details.providerName != null)
                        Text(
                          isolated(details.providerName!),
                          style: theme.textTheme.titleMedium,
                        ),
                      SelectableText(isolated(details.origin)),
                      if (details.cleartext) ...[
                        const SizedBox(height: 8),
                        _WarningLine(
                          icon: Icons.no_encryption_outlined,
                          text: l10n.aiConsentUnencrypted,
                        ),
                      ],
                      const SizedBox(height: 12),
                      _LabelValue(
                        label: l10n.aiConsentFormatHeading,
                        value: _formatLabel(details.format),
                      ),
                      if (details.model != null)
                        _LabelValue(
                          label: l10n.aiConsentModelHeading,
                          value: isolated(details.model!),
                        ),
                    ],
                  ),
                  _InfoCard(
                    icon: Icons.data_object,
                    title: l10n.aiConsentDataHeading,
                    children: [
                      Text(l10n.aiConsentDataDescription),
                      const SizedBox(height: 8),
                      for (final category in details.categories)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsetsDirectional.only(top: 8),
                                child: Icon(Icons.circle, size: 6),
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(_categoryLabel(category))),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        details.toolsEnabled
                            ? l10n.aiConsentToolsEnabled
                            : l10n.aiConsentToolsDisabled,
                      ),
                    ],
                  ),
                  if (details.writeCeiling case final ceiling?)
                    _InfoCard(
                      key: const ValueKey('ai-consent-writes'),
                      icon: Icons.edit_note_outlined,
                      title: l10n.aiConsentWritesHeading,
                      children: [
                        Text(l10n.aiConsentWritesUpTo(aiLevelLabel(ceiling))),
                        const SizedBox(height: 4),
                        Text(aiLevelHint(ceiling)),
                        for (final line in [
                          l10n.aiConsentWritesLimits,
                          if (details.groupWrites)
                            l10n.aiConsentWritesGroupScope,
                          l10n.aiConsentWritesNoUndo,
                          l10n.aiConsentWritesUncertain(l10n.aiWriteLogTitle),
                          if (ceiling.index >=
                              AiAutonomyLevel.conversationGrant.index)
                            l10n.aiConsentWritesUploads,
                          l10n.aiConsentWritesInstructions,
                          l10n.aiConsentWritesPipelines,
                        ]) ...[const SizedBox(height: 8), Text(line)],
                      ],
                    ),
                  _InfoCard(
                    icon: Icons.policy_outlined,
                    title: l10n.aiConsentDataUseHeading,
                    children: [
                      _DataUseNotice(
                        dataUse: details.dataUse,
                        retentionDays: details.retentionDays,
                      ),
                      const SizedBox(height: 8),
                      if (details.policyUri case final policyUri?)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            onPressed: () => openExternal(context, policyUri),
                            icon: const Icon(Icons.open_in_new),
                            label: Text(l10n.aiConsentViewPolicy),
                          ),
                        )
                      else
                        Text(l10n.aiConsentCustomPolicy),
                    ],
                  ),
                  _InfoCard(
                    icon: Icons.apartment_outlined,
                    title: l10n.aiConsentOrganizationHeading,
                    children: [Text(l10n.aiConsentSelfManagedNotice)],
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l10n.aiConsentIrreversible,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: widget.readOnly
                      ? FilledButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text(l10n.closeAction),
                        )
                      : Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: _saving
                                  ? null
                                  : () => Navigator.of(context).pop(false),
                              child: Text(l10n.cancelAction),
                            ),
                            FilledButton(
                              onPressed: _saving ? null : _agree,
                              child: _saving
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      widget.agreeLabel ??
                                          l10n.aiConsentAgreeAndSend,
                                    ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
              if (children.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...children,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LabelValue extends StatelessWidget {
  const _LabelValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _WarningLine extends StatelessWidget {
  const _WarningLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DataUseNotice extends StatelessWidget {
  const _DataUseNotice({required this.dataUse, this.retentionDays});

  final AiDataUse dataUse;
  final int? retentionDays;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dataUse == AiDataUse.training)
          _WarningLine(
            icon: Icons.model_training,
            text: l10n.aiConsentTrainingWarning,
          )
        else if (dataUse == AiDataUse.unknown)
          _WarningLine(
            icon: Icons.help_outline,
            text: l10n.aiConsentUnknownDataUseWarning,
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(l10n.aiConsentNoTraining)),
            ],
          ),
        const SizedBox(height: 4),
        if (retentionDays != null)
          _LabelValue(
            label: l10n.aiConsentRetentionDays,
            value: MaterialLocalizations.of(
              context,
            ).formatDecimal(retentionDays!),
          )
        else
          Text(l10n.aiConsentRetentionNotStated),
      ],
    );
  }
}

final class _ConsentDetails {
  const _ConsentDetails({
    required this.origin,
    required this.format,
    required this.cleartext,
    required this.toolsEnabled,
    required this.categories,
    required this.dataUse,
    this.providerName,
    this.model,
    this.retentionDays,
    this.policyUri,
    this.grantedAt,
    this.writeCeiling,
    this.groupWrites = false,
  });

  factory _ConsentDetails.fromSummary(
    Map<String, Object?> summary, {
    DateTime? grantedAt,
  }) {
    final rawCategories =
        summary['dataCategories'] ?? summary['categories'] ?? const <Object?>[];
    final categories = rawCategories is List
        ? rawCategories.whereType<String>().toList(growable: false)
        : const <String>[];
    final policyUrl = summary['policyUrl'];
    return _ConsentDetails(
      providerName: summary['providerName'] is String
          ? summary['providerName'] as String
          : null,
      origin: summary['origin'] is String
          ? summary['origin'] as String
          : summary['recipient'] is String
          ? summary['recipient'] as String
          : '',
      format: _formatFromName(summary['format']),
      cleartext: summary['cleartext'] == true,
      toolsEnabled: summary['toolsEnabled'] == true,
      categories: categories,
      model: summary['model'] is String ? summary['model'] as String : null,
      dataUse: _dataUseFromName(summary['dataUse']),
      retentionDays: summary['retentionDays'] is int
          ? summary['retentionDays'] as int
          : null,
      policyUri: policyUrl is String ? _safePolicyUri(policyUrl) : null,
      grantedAt: grantedAt,
      writeCeiling: switch (summary['writePolicy']) {
        {'agreedCeiling': final String name}
            when name != AiAutonomyLevel.readOnly.name =>
          AiAutonomyLevel.values.asNameMap()[name],
        _ => null,
      },
      groupWrites: switch (summary['writePolicy']) {
        {'operationIds': final List<Object?> ids} => ids.any(
          (id) =>
              id is String &&
              productionAiLedger.find(id)?.scopeClass ==
                  AiScopeClass.groupWorkItem,
        ),
        _ => false,
      },
    );
  }

  final String? providerName;
  final String origin;
  final AiFormat format;
  final bool cleartext;
  final bool toolsEnabled;
  final List<String> categories;
  final String? model;
  final AiDataUse dataUse;
  final int? retentionDays;
  final Uri? policyUri;
  final DateTime? grantedAt;

  /// The highest level the AI may write at; null for a read-only consent.
  final AiAutonomyLevel? writeCeiling;

  /// Whether the agreed policy lists a write to a group's own work item.
  /// Read from the saved policy itself, so the scope sentence appears with
  /// the first policy that offers those writes and a saved record shows
  /// exactly what was agreed; the hash is untouched.
  final bool groupWrites;
}

String _formatLabel(AiFormat format) => switch (format) {
  AiFormat.chatCompletions => l10n.aiConsentFormatChatCompletions,
  AiFormat.responses => l10n.aiConsentFormatResponses,
  AiFormat.anthropicMessages => l10n.aiConsentFormatAnthropicMessages,
};

String _categoryLabel(String category) => switch (category) {
  'job_log' || 'job_logs' => l10n.aiConsentCategoryJobLog,
  'diff' || 'diffs' || 'mr_diff' || 'commit_diff' => l10n.aiConsentCategoryDiff,
  'source' || 'file' || 'files' || 'repository' => l10n.aiConsentCategorySource,
  'issue' || 'issue_text' || 'issues' => l10n.aiConsentCategoryIssueText,
  'comment' ||
  'comments' ||
  'discussion' ||
  'discussions' => l10n.aiConsentCategoryComments,
  'tool_read' || 'tool_reads' => l10n.aiConsentCategoryToolReads,
  'write_results' => l10n.aiConsentCategoryWriteResults,
  'attachment_metadata' => l10n.aiConsentCategoryAttachmentMetadata,
  _ => l10n.aiConsentCategoryOther,
};

AiFormat _formatFromName(Object? value) => AiFormat.values.firstWhere(
  (candidate) => candidate.name == value,
  orElse: () => AiFormat.chatCompletions,
);

AiDataUse _dataUseFromName(Object? value) => AiDataUse.values.firstWhere(
  (candidate) => candidate.name == value,
  orElse: () => AiDataUse.unknown,
);

Uri? _safePolicyUri(String value) {
  final uri = Uri.tryParse(value);
  return uri != null && safeExternalUri(uri) ? uri : null;
}

String _dateTime(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final localization = MaterialLocalizations.of(context);
  return '${localization.formatMediumDate(local)} '
      '${localization.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}
