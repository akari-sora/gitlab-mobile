import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ai/ai_report.dart';
import '../../core/brand.dart';
import '../../l10n/l10n.dart';
import '../../shared/theme.dart';

/// What the user chose in the report sheet.
typedef AiReportChoice = ({
  AiReportCategory category,
  String description,
  bool attachResponse,
});

/// Asks what is wrong with an answer and shows exactly what would be sent.
/// [body] builds the report text for a choice, for the preview. Returns the
/// choice when the user sends, or null when they back out; the caller sends.
Future<AiReportChoice?> showAiReportSheet(
  BuildContext context, {
  required String Function(AiReportChoice choice) body,
}) => showModalBottomSheet<AiReportChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => AiReportSheet(body: body),
);

class AiReportSheet extends StatefulWidget {
  const AiReportSheet({super.key, required this.body});

  final String Function(AiReportChoice choice) body;

  @override
  State<AiReportSheet> createState() => _AiReportSheetState();
}

class _AiReportSheetState extends State<AiReportSheet> {
  final _description = TextEditingController();
  AiReportCategory? _category;
  var _attach = false;

  /// "Copied" shows on the button itself: the sheet sits above the chat's
  /// own messenger, so a snack bar would not be seen.
  var _copied = false;
  Timer? _copiedReset;

  /// Typing refreshes the preview after a pause instead of on every key: the
  /// attached answer can be 64,000 characters to clean, check and lay out.
  Timer? _typing;
  AiReportChoice? _previewed;
  String _preview = '';

  @override
  void dispose() {
    _copiedReset?.cancel();
    _typing?.cancel();
    _description.dispose();
    super.dispose();
  }

  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() {});
    });
  }

  String _previewOf(AiReportChoice choice) {
    if (choice != _previewed) {
      _previewed = choice;
      _preview = widget.body(choice);
    }
    return _preview;
  }

  Future<void> _copyAddress() async {
    await Clipboard.setData(const ClipboardData(text: aiReportEmail));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  AiReportChoice? get _choice {
    final category = _category;
    if (category == null) return null;
    return (
      category: category,
      description: _description.text.trim(),
      attachResponse: _attach,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final keyboard = media.viewInsets.bottom;
    final choice = _choice;
    return LayoutBuilder(
      builder: (context, constraints) {
        // As in the append preview: the constraints already leave out the
        // status bar and the drag handle; the keyboard is taken off here.
        final room = math.max(0.0, constraints.maxHeight - keyboard);
        final height = room < 420 ? room : room * 0.9;
        // With little room (a landscape phone with the keyboard up) the
        // buttons scroll with the form instead of being pinned under it.
        final pinned = room >= 240;
        final actions = Padding(
          padding: EdgeInsets.fromLTRB(
            pinned ? 16 : 0,
            8,
            pinned ? 16 : 0,
            8 + (keyboard > 0 ? 0 : media.padding.bottom),
          ),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.cancelAction),
              ),
              FilledButton.icon(
                key: const ValueKey('ai-report-send'),
                icon: const Icon(Icons.outlined_flag, size: 18),
                label: Text(l10n.aiReportSend),
                // The choice as it is now: typing does not rebuild the sheet.
                onPressed: choice == null
                    ? null
                    : () => Navigator.of(context).pop(_choice),
              ),
            ],
          ),
        );
        final form = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.aiReportTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(l10n.aiReportIntro, style: muted),
            const SizedBox(height: 12),
            Text(l10n.aiReportCategory, style: theme.textTheme.labelLarge),
            RadioGroup<AiReportCategory>(
              groupValue: _category,
              onChanged: (value) => setState(() => _category = value),
              child: Column(
                children: [
                  for (final category in AiReportCategory.values)
                    RadioListTile<AiReportCategory>(
                      key: ValueKey('ai-report-${category.name}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: category,
                      title: Text(_categoryLabel(category)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ai-report-description'),
              controller: _description,
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              onChanged: _typed,
              decoration: InputDecoration(labelText: l10n.aiReportDescription),
            ),
            SwitchListTile(
              key: const ValueKey('ai-report-attach'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l10n.aiReportAttach),
              subtitle: Text(l10n.aiReportAttachHint),
              value: _attach,
              onChanged: (value) => setState(() => _attach = value),
            ),
            const SizedBox(height: 4),
            // Text first, button under it: a long address or
            // label at large text sizes must not overflow.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.mail_outline, size: 18, color: muted?.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.aiReportDestination(aiReportEmail),
                    style: muted,
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('ai-report-copy-address'),
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                onPressed: _copyAddress,
                label: Text(
                  _copied
                      ? l10n.aiReportAddressCopied
                      : l10n.aiReportCopyAddress,
                ),
              ),
            ),
            if (choice != null) ...[
              const SizedBox(height: 8),
              Text(l10n.aiReportPreview, style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      _previewOf(choice),
                      key: const ValueKey('ai-report-preview'),
                      style: codeTextStyle(context, fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('ai-report-scroll'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: pinned
                        ? form
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [form, actions],
                          ),
                  ),
                ),
                if (pinned) ...[const Divider(height: 1), actions],
              ],
            ),
          ),
        );
      },
    );
  }
}

String _categoryLabel(AiReportCategory category) => switch (category) {
  AiReportCategory.harmful => l10n.aiReportHarmful,
  AiReportCategory.inaccurate => l10n.aiReportInaccurate,
  AiReportCategory.privacy => l10n.aiReportPrivacy,
  AiReportCategory.other => l10n.aiReportOther,
};
