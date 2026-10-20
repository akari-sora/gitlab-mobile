import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/suggestion.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';

import '../../l10n/l10n.dart';
/// Renders a GitLab code suggestion with diff styling and one-tap apply button.
class SuggestedChangeCard extends StatefulWidget {
  const SuggestedChangeCard({
    super.key,
    required this.suggestion,
    this.api,
    this.onApplied,
  });

  final SuggestedChange suggestion;
  final GitLabApi? api;
  final VoidCallback? onApplied;

  @override
  State<SuggestedChangeCard> createState() => _SuggestedChangeCardState();
}

class _SuggestedChangeCardState extends State<SuggestedChangeCard> {
  late SuggestedChange _current = widget.suggestion;
  bool _applying = false;

  @override
  void didUpdateWidget(SuggestedChangeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.suggestion != widget.suggestion) {
      _current = widget.suggestion;
    }
  }

  Future<void> _applySuggestion() async {
    final api = widget.api;
    final id = _current.id;
    if (api == null || id == null || _applying) return;

    final commitMessage = await showDialog<String>(
      context: context,
      builder: (_) => const _ApplySuggestionDialog(),
    );

    if (commitMessage == null || !mounted) return;

    setState(() => _applying = true);
    try {
      await api.applySuggestion(
        id,
        commitMessage: commitMessage.isNotEmpty ? commitMessage : null,
      );
      if (mounted) {
        setState(() {
          _current = _current.copyWith(applied: true);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.suggestionApplied)),
        );
        widget.onApplied?.call();
      }
    } catch (e) {
      if (mounted) {
        showFailure(context, e);
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final normalizedFrom = _current.fromContent.replaceAll('\r\n', '\n').trimRight();
    final normalizedTo = _current.toContent.replaceAll('\r\n', '\n').trimRight();
    final fromLines = normalizedFrom.isEmpty
        ? const <String>[]
        : normalizedFrom.split('\n');
    final toLines = normalizedTo.isEmpty
        ? const <String>[]
        : normalizedTo.split('\n');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900 : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.difference_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.suggestedChange,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_current.applied)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle, size: 12, color: Colors.green),
                        const SizedBox(width: 4),
                        Text(
                          l10n.applied,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (!_current.appliable)
                  Text(
                    l10n.cannotAutoApply,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (fromLines.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.red.shade900.withValues(alpha: 0.25)
                          : const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Directionality(textDirection: TextDirection.ltr, child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in fromLines)
                          Text(
                            '- $line',
                            style: TextStyle(
                              fontFamily: codeFontFamily,
                              fontFamilyFallback: const ['Menlo', 'monospace'],
                              fontSize: 12,
                              color: isDark ? Colors.red.shade200 : const Color(0xFFC62828),
                            ),
                          ),
                      ],
                    )),
                  ),
                if (toLines.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.green.shade900.withValues(alpha: 0.25)
                          : const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Directionality(textDirection: TextDirection.ltr, child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in toLines)
                          Text(
                            '+ $line',
                            style: TextStyle(
                              fontFamily: codeFontFamily,
                              fontFamilyFallback: const ['Menlo', 'monospace'],
                              fontSize: 12,
                              color: isDark ? Colors.green.shade200 : const Color(0xFF2E7D32),
                            ),
                          ),
                      ],
                    )),
                  ),
                if (fromLines.isEmpty && toLines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      l10n.noChangeContent,
                      style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ),
          ),
          if (!_current.applied && _current.appliable && _current.id != null && widget.api != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  key: ValueKey('apply-suggestion-${_current.id}'),
                  onPressed: _applying ? null : _applySuggestion,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  icon: _applying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check, size: 16),
                  label: Text(l10n.applySuggestion),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ApplySuggestionDialog extends StatefulWidget {
  const _ApplySuggestionDialog();

  @override
  State<_ApplySuggestionDialog> createState() => _ApplySuggestionDialogState();
}

class _ApplySuggestionDialogState extends State<_ApplySuggestionDialog> {
  late final TextEditingController _controller = TextEditingController(text: 'Apply suggestion to code');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(l10n.applySuggestedChange),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.suggestionCreatesCommit),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: l10n.suggestionCommitMessage,
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
          ),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.confirmApply),
        ),
      ],
    );
  }
}
