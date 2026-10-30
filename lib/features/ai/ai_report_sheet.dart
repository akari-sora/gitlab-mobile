import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

/// What the sheet hands back on Send: the choice and the exact text the
/// user saw, or a null text when it could not be checked.
typedef AiReportSheetResult = ({AiReportChoice choice, String? text});

/// Asks what is wrong with an answer and shows exactly what would be sent.
/// [body] builds the report text for the preview. At Send, [prepare] builds
/// it once more with the live secrets; the sheet returns it only when it
/// matches the preview, and otherwise shows the new text to confirm.
/// Null when the user backs out; the caller sends.
Future<AiReportSheetResult?> showAiReportSheet(
  BuildContext context, {
  required String Function(AiReportChoice choice) body,
  required Future<String?> Function(AiReportChoice choice) prepare,
}) => showModalBottomSheet<AiReportSheetResult>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => AiReportSheet(body: body, prepare: prepare),
);

class AiReportSheet extends StatefulWidget {
  const AiReportSheet({super.key, required this.body, required this.prepare});

  final String Function(AiReportChoice choice) body;
  final Future<String?> Function(AiReportChoice choice) prepare;

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

  var _sending = false;

  /// The preview changed at Send (an answer rebuilt, a secret rotated, the
  /// last keys typed): the user confirms the new text with a second Send.
  var _previewUpdated = false;

  /// The note and the preview, brought into view when Send replaced it.
  final _previewBox = GlobalKey();

  /// The Cancel and Send row, measured after each layout: whether the
  /// buttons can stay pinned above the keyboard depends on their real height
  /// (text size, language, wrapping), not on a constant.
  final _buttonsBox = GlobalKey();
  var _buttonsHeight = 48.0;

  void _measureButtons() {
    final box = _buttonsBox.currentContext?.findRenderObject();
    if (!mounted || box is! RenderBox || !box.hasSize) return;
    final height = box.size.height;
    if ((height - _buttonsHeight).abs() > 0.5) {
      setState(() => _buttonsHeight = height);
    }
  }

  Future<void> _send() async {
    final choice = _choice;
    if (choice == null || _sending) return;
    _typing?.cancel();
    // What the user has seen, taken before the rebuild below can refresh
    // the preview with keys typed in the last moment.
    final shown = _previewed == choice ? _preview : null;
    setState(() => _sending = true);
    String? text;
    try {
      text = await widget.prepare(choice);
    } on Object {
      text = null;
    }
    // Backed out while the text was being checked: the sheet is closing,
    // and popping now would close the page under it.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    if (text != null && text != shown) {
      setState(() {
        _previewed = choice;
        _preview = text!;
        _previewUpdated = true;
        _sending = false;
      });
      // Said out loud now: the note may still be outside the scroller this
      // frame, and Android drops a live-region change on a hidden node.
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          l10n.aiReportPreviewUpdated,
          Directionality.of(context),
        ),
      );
      // The note asks the user to check the preview: show its start.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final box = _previewBox.currentContext;
        if (box != null && box.mounted) {
          unawaited(
            Scrollable.ensureVisible(
              box,
              duration: const Duration(milliseconds: 200),
            ),
          );
        }
      });
      return;
    }
    Navigator.of(context).pop((choice: choice, text: text));
  }

  String _previewOf(AiReportChoice choice) {
    if (choice != _previewed) {
      _previewed = choice;
      _preview = widget.body(choice);
      _previewUpdated = false;
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
    // First, so a new choice has cleared the "preview updated" note before
    // the buttons below are built.
    final preview = choice == null ? null : _previewOf(choice);
    return LayoutBuilder(
      builder: (context, constraints) {
        // As in the append preview: the constraints already leave out the
        // status bar and the drag handle; the keyboard is taken off here.
        final room = math.max(0.0, constraints.maxHeight - keyboard);
        final height = room < 420 ? room : room * 0.9;
        final bottomInset = keyboard > 0 ? 0.0 : media.padding.bottom;
        // With little room (a landscape phone with the keyboard up) the
        // buttons scroll with the form instead of being pinned under it:
        // pinned, the form keeps at least 100 dp next to the measured footer.
        // Both ways the row is laid out at the same width, so the measurement
        // does not change with the choice.
        final pinned = room - (_buttonsHeight + 16 + bottomInset) >= 100;
        WidgetsBinding.instance.addPostFrameCallback((_) => _measureButtons());
        final note = _previewUpdated
            ? Padding(
                padding: const EdgeInsets.only(bottom: 6),
                // Announced by Send itself (see _send), not a live region:
                // iOS would read it twice.
                child: Text(
                  l10n.aiReportPreviewUpdated,
                  key: const ValueKey('ai-report-preview-updated'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              )
            : null;
        final buttons = Wrap(
          key: _buttonsBox,
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
              onPressed: choice == null || _sending ? null : _send,
            ),
          ],
        );
        final actionsPadding = EdgeInsets.fromLTRB(
          pinned ? 16 : 0,
          8,
          pinned ? 16 : 0,
          8 + bottomInset,
        );
        // Pinned, the footer leaves the form at least 120 dp for the preview;
        // whatever does not fit scrolls, kept at its end so Send is always on
        // screen.
        final actions = pinned
            ? ConstrainedBox(
                // Measured against the sheet's own height, which is 90% of
                // a large room.
                constraints: BoxConstraints(maxHeight: height - 120),
                child: SingleChildScrollView(
                  // Not the route's primary scroller: that is the form's.
                  primary: false,
                  reverse: true,
                  padding: actionsPadding,
                  child: buttons,
                ),
              )
            : Padding(padding: actionsPadding, child: buttons);
        final form = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.aiReportTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(l10n.aiReportFormIntro, style: muted),
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
            // The fallback address, in case the form cannot be reached.
            // Text first, button under it: a long address or label at large
            // text sizes must not overflow.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.mail_outline, size: 18, color: muted?.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.aiReportMailFallback(aiReportEmail),
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
              // The note sits right above the text it asks the user to check,
              // in the form: in the footer's scroller it could be scrolled
              // out of view above Send at large text with the keyboard up.
              Column(
                key: _previewBox,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?note,
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          preview!,
                          key: const ValueKey('ai-report-preview'),
                          style: codeTextStyle(context, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
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
                    // The form keeps its place in the tree whether the buttons
                    // are pinned or scroll with it, so the description field
                    // keeps its focus and the keyboard when the room changes.
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [form, if (!pinned) actions],
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
