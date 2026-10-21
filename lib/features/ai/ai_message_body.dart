import 'package:flutter/material.dart';

import '../../shared/markdown_view.dart';
import '../../shared/theme.dart';

/// Above this many UTF-16 code units a reply is split into several views.
const aiMarkdownSingleViewLimit = 60000;

/// The size each split part aims for.
const aiMarkdownSegmentTarget = 48000;

/// While streaming, a reply longer than this is shown as plain text and only
/// laid out as Markdown once it is complete.
const aiStreamingMarkdownLimit = 20000;

/// Splits [text] at blank lines outside fenced code blocks into parts of at
/// most [target] code units, so each part can be laid out on its own. A
/// single block longer than [target] stays one part.
List<String> splitAiMarkdown(
  String text, {
  int target = aiMarkdownSegmentTarget,
}) {
  final blocks = <String>[];
  final current = StringBuffer();
  String? fence;
  for (final line in text.split('\n')) {
    final trimmed = line.trimLeft();
    final indent = line.length - trimmed.length;
    if (indent <= 3) {
      final marker = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed)?.group(1);
      if (marker != null) {
        if (fence == null) {
          fence = marker;
        } else if (marker[0] == fence[0] &&
            marker.length >= fence.length &&
            trimmed.substring(marker.length).trim().isEmpty) {
          fence = null;
        }
      }
    }
    if (current.isNotEmpty) current.write('\n');
    current.write(line);
    if (fence == null && line.trim().isEmpty) {
      blocks.add(current.toString());
      current.clear();
    }
  }
  if (current.isNotEmpty) blocks.add(current.toString());

  final parts = <String>[];
  final part = StringBuffer();
  for (final block in blocks) {
    if (part.isNotEmpty && part.length + 1 + block.length > target) {
      parts.add(part.toString());
      part.clear();
    }
    if (part.isNotEmpty) part.write('\n');
    part.write(block);
  }
  if (part.isNotEmpty) parts.add(part.toString());
  return parts;
}

/// An assistant reply. Never fetches anything on its own (images, media and
/// links wait for the user), and stays responsive for very long replies.
class AiMessageBody extends StatelessWidget {
  const AiMessageBody({super.key, required this.text, this.streaming = false});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    if (streaming && text.length > aiStreamingMarkdownLimit) {
      return _PlainReply(text);
    }
    if (text.length <= aiMarkdownSingleViewLimit) {
      return MarkdownView(text, offline: true);
    }
    final parts = splitAiMarkdown(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final part in parts)
          part.length > aiMarkdownSingleViewLimit
              ? _PlainReply(part, monospace: true)
              : MarkdownView(part, offline: true),
      ],
    );
  }
}

class _PlainReply extends StatelessWidget {
  const _PlainReply(this.text, {this.monospace = false});

  final String text;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return SelectableText(
      text,
      style: monospace
          ? style?.copyWith(
              fontFamily: codeFontFamily,
              fontFamilyFallback: const ['Menlo', 'monospace'],
            )
          : style,
    );
  }
}
