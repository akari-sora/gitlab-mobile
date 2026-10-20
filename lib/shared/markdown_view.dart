import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'artifact_storage.dart';
import 'attachment_budget.dart';
import 'attachment_download.dart';
import 'attachment_image.dart';
import 'attachment_ref.dart';
import 'external_link.dart';
import 'in_app_links.dart';
import 'theme.dart';

import '../l10n/l10n.dart';

final _htmlComment = RegExp(r'<!--[\s\S]*?(?:-->|$)');
final _htmlTag = RegExp(r'</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>\n]*)?/?>');
final _image = RegExp(r'!\[([^\]\n]*)\]\([^)\n]*\)');
final _link = RegExp(r'\[([^\]\n]*)\]\([^)\n]*\)');
final _heading = RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+', multiLine: true);
final _quote = RegExp(r'^[ \t]{0,3}>[ \t]?', multiLine: true);
final _fenceOrRule = RegExp(r'^[ \t]{0,3}(?:(?:`{3,}|~{3,})[^\n]*|(?:[-*_][ \t]*){3,})$', multiLine: true);
final _codeSpan = RegExp(r'`+([^`\n]+?)`+');
final _strongOrStrike = RegExp(r'\*\*|~~');

/// The readable start of Markdown [source], for a one-paragraph summary:
/// HTML comments and tags, images, heading, quote, fence and rule markers,
/// bold and strike markers, code ticks and link targets are dropped. `text` holds at
/// most [limit] characters; `more` tells whether the source goes on.
({String text, bool more}) markdownSummary(String source, int limit) {
  final visible = source.replaceAll(_htmlComment, '');
  // Markup only shortens the text, so twice the limit leaves room for it.
  final head = visible.characters.take(limit * 2 + 1);
  final plain = head
      .take(limit * 2)
      .toString()
      .replaceAll(_htmlTag, '')
      .replaceAll(_image, '')
      .replaceAllMapped(_link, (match) => match[1]!)
      .replaceAll(_heading, '')
      .replaceAll(_quote, '')
      .replaceAll(_fenceOrRule, '')
      .replaceAllMapped(_codeSpan, (match) => match[1]!)
      .replaceAll(_strongOrStrike, '')
      .characters;
  return (
    text: plain.take(limit).toString(),
    more: head.length > limit * 2 || plain.length > limit,
  );
}

final _letter = RegExp(r'\p{L}', unicode: true);

/// The direction of the first letter in [text], the Unicode "first strong"
/// rule that HTML's `dir="auto"` uses, or null when it has no letter.
TextDirection? firstStrongDirection(String text) {
  final letter = _letter.firstMatch(text);
  if (letter == null) return null;
  final rune = letter[0]!.runes.first;
  final rtl = (rune >= 0x0590 && rune <= 0x08FF) ||
      (rune >= 0xFB1D && rune <= 0xFDFF) ||
      (rune >= 0xFE70 && rune <= 0xFEFF) ||
      (rune >= 0x10800 && rune <= 0x10FFF) ||
      (rune >= 0x1E800 && rune <= 0x1EFFF);
  return rtl ? TextDirection.rtl : TextDirection.ltr;
}

class MarkdownView extends StatefulWidget {
  const MarkdownView(
    this.text, {
    super.key,
    this.base,
    this.api,
    this.projectId,
    this.projectWeb,
    this.projectPath,
    this.budget,
    this.account,
    this.sharer = const SystemArtifactSharer(),
    this.downloader,
    this.selectable = true,
  });
  final String text;
  final Uri? base;
  final GitLabApi? api;
  final int? projectId;
  final Uri? projectWeb;
  final String? projectPath;

  /// When omitted, this view keeps one budget for its lifetime. Pass a parent
  /// budget to share the cap across several views on the same page.
  final AttachmentBudget? budget;
  final Account? account;
  final ArtifactSharer sharer;
  final AttachmentDownloader? downloader;
  final bool selectable;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  AttachmentBudget? _owned;
  // Markdown's unkeyed horizontal scroll views must not read an ancestor
  // ExpansionTile's boolean state as a scroll offset.
  final _scrollStorage = PageStorageBucket();

  AttachmentBudget get _budget => widget.budget ?? (_owned ??= AttachmentBudget());

  // The body follows its own first letter, like dir="auto": an English README
  // reads left to right in the Arabic interface, an Arabic one right to left.
  String? _directionSource;
  TextDirection? _direction;

  TextDirection? _directionOf(String text) {
    if (!identical(text, _directionSource)) {
      _directionSource = text;
      _direction = firstStrongDirection(markdownSummary(text, 200).text);
    }
    return _direction;
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.budget != null) return;
    if (oldWidget.text != widget.text || oldWidget.projectId != widget.projectId) {
      _owned = AttachmentBudget();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    if (text.length > 65536) {
      return Text(l10n.markdownLayoutLimit);
    }
    final budget = _budget;
    final base = widget.base;
    final api = widget.api;
    final projectId = widget.projectId;
    final projectWeb = widget.projectWeb;
    final tableTextScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.0);
    final body = MarkdownBody(data: text, selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        h1: Theme.of(context).textTheme.headlineSmall,
        h2: Theme.of(context).textTheme.titleLarge,
        h3: Theme.of(context).textTheme.titleMedium,
        tableColumnWidth: FixedColumnWidth(180.0 * tableTextScale),
        tableScrollbarThumbVisibility: true,
        code: TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: const ['Menlo', 'monospace'], fontSize: 13, color: Theme.of(context).colorScheme.onSurface),
        codeblockDecoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12)),
        blockquoteDecoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12)),
      ),
      // Only this project's upload API is fetched. Other images stay icon-only.
      imageBuilder: (uri, title, alt) {
        final ref = parseProjectUpload(uri, base: base, projectId: projectId, projectWeb: projectWeb);
        final client = api;
        final id = projectId;
        if (ref != null && client != null && id != null) {
          return AttachmentImage(
            api: client,
            budget: budget,
            projectId: id,
            secret: ref.secret,
            filename: ref.filename,
            alt: alt,
            projectWeb: projectWeb,
            projectPath: widget.projectPath,
          );
        }
        return attachmentImageFallback(alt);
      },
      onTapLink: (_, href, _) async {
        if (href == null) { return; }
        final parsed = Uri.tryParse(href);
        if (parsed == null) { return; }
        final uri = parsed.hasScheme ? parsed : base?.resolveUri(parsed);
        if (uri == null || !safeExternalUri(uri)) {
          return;
        }
        final uploadRef = parseProjectUpload(uri, base: base, projectId: projectId, projectWeb: projectWeb);
        if (uploadRef != null && api != null && projectId != null) {
          Account? activeAccount = widget.account;
          if (activeAccount == null) {
            try {
              activeAccount = ProviderScope.containerOf(context, listen: false).read(sessionProvider).active;
            } catch (_) {}
          }
          if (activeAccount != null) {
            await showAttachmentDownloadSheet(
              context,
              api: api,
              projectId: projectId,
              secret: uploadRef.secret,
              filename: uploadRef.filename,
              account: activeAccount,
              projectPath: widget.projectPath,
              webUri: uri,
              sharer: widget.sharer,
              downloader: widget.downloader,
            );
            return;
          }
        }
        final inApp = InAppLinks.maybeOf(context);
        if (inApp != null && (await inApp(context, uri) || !context.mounted)) {
          return;
        }
        await openExternal(context, uri);
      },
    );
    final direction = _directionOf(text);
    final content = widget.selectable ? SelectionArea(child: body) : body;
    return PageStorage(
      bucket: _scrollStorage,
      child: direction == null || direction == Directionality.of(context)
          ? content
          : Directionality(textDirection: direction, child: content),
    );
  }
}
