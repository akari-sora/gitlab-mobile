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

// CommonMark 0.31: `<!-->` and `<!--->` are complete comments.
final _comment = RegExp(r'<!--(?:-?>|.*?-->)');
final _openingFence = RegExp(r'^[ \t]{0,3}(?:(`{3,})[^`]*|(~{3,}).*)$');
final _closingFence = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})[ \t]*$');
final _ruleOrUnderline = RegExp(r'^[ \t]{0,3}(?:(?:[-*_][ \t]*){3,}|=+[ \t]*)$');
final _blockPrefix = RegExp(r'^[ \t]{0,3}(?:>[ \t]?)*[ \t]*(?:#{1,6}(?:[ \t]+|$))?');
final _htmlTag = RegExp(r'</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>');
// A destination may hold one level of parentheses: `(…/Foo_(bar))`.
final _image = RegExp(r'!\[[^\]]*\]\((?:[^()]|\([^()]*\))*\)');
final _link = RegExp(r'\[([^\]]*)\]\((?:[^()]|\([^()]*\))*\)');
final _strongOrStrike = RegExp(r'\*\*|~~');
final _underscoreStrong = RegExp(r'(?<![A-Za-z0-9_])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9_])');

/// How much of a long description is scanned for its summary.
const _summaryScanLimit = 65536;

/// The readable start of Markdown [source], for a one-paragraph summary.
/// Code keeps its text; HTML comments and tags, images, heading, quote,
/// fence and rule markers, bold and strike markers, code ticks and link
/// targets are dropped. `text` holds at most [limit] characters; `more`
/// tells whether readable text goes on past it.
({String text, bool more}) markdownSummary(String source, int limit) {
  final out = StringBuffer();
  String? fence;
  var inComment = false;
  var more = false;
  var start = 0;
  while (start < source.length) {
    if (start > _summaryScanLimit) {
      more = !inComment || source.contains('-->', start);
      break;
    }
    final newline = source.indexOf('\n', start);
    final end = newline < 0 ? source.length : newline;
    var line = source.substring(start, end);
    start = end + 1;
    final open = fence;
    if (open != null) {
      final close = _closingFence.firstMatch(line)?[1];
      if (close != null && close[0] == open[0] && close.length >= open.length) {
        fence = null;
      } else {
        out.writeln(line);
      }
    } else {
      if (inComment) {
        final close = line.indexOf('-->');
        if (close < 0) continue;
        line = line.substring(close + 3);
        inComment = false;
      }
      final opening = _openingFence.firstMatch(line);
      if (opening != null) {
        fence = opening[1] ?? opening[2];
        continue;
      }
      if (_ruleOrUnderline.hasMatch(line)) continue;
      final readable = _readableLine(line.replaceFirst(_blockPrefix, ''));
      inComment = readable.inComment;
      out.writeln(readable.text);
    }
    if (out.length > limit && out.toString().characters.length > limit) {
      more = true;
      break;
    }
  }
  final text = out.toString().characters;
  return (text: text.take(limit).toString(), more: more || text.length > limit);
}

/// One line's readable text, scanning code spans and comments left to right
/// as CommonMark does. `inComment` is set when a comment runs past the line.
({String text, bool inComment}) _readableLine(String line) {
  final out = StringBuffer();
  var plainStart = 0;
  var i = 0;
  void flush(int to) => out.write(_inlineText(line.substring(plainStart, to)));
  while (i < line.length) {
    if (line.codeUnitAt(i) == 0x60) {
      var run = i;
      while (run < line.length && line.codeUnitAt(run) == 0x60) {
        run++;
      }
      final ticks = run - i;
      var close = run;
      while (true) {
        close = line.indexOf('`', close);
        if (close < 0) break;
        var closeEnd = close;
        while (closeEnd < line.length && line.codeUnitAt(closeEnd) == 0x60) {
          closeEnd++;
        }
        if (closeEnd - close == ticks) break;
        close = closeEnd;
      }
      if (close < 0) {
        i = run;
        continue;
      }
      flush(i);
      var code = line.substring(run, close);
      if (code.length > 1 && code.startsWith(' ') && code.endsWith(' ') && code.trim().isNotEmpty) {
        code = code.substring(1, code.length - 1);
      }
      out.write(code);
      i = close + ticks;
      plainStart = i;
      continue;
    }
    if (line.startsWith('<!--', i)) {
      flush(i);
      final comment = _comment.matchAsPrefix(line, i);
      if (comment == null) return (text: out.toString(), inComment: true);
      i = comment.end;
      plainStart = i;
      continue;
    }
    i++;
  }
  flush(line.length);
  return (text: out.toString(), inComment: false);
}

String _inlineText(String text) => text
    .replaceAll(_htmlTag, '')
    .replaceAll(_image, '')
    .replaceAllMapped(_link, (match) => match[1]!)
    .replaceAllMapped(_underscoreStrong, (match) => match[1]!)
    .replaceAll(_strongOrStrike, '');

// The first strong character: a letter, or an explicit LRM, RLM or ALM mark.
final _strong = RegExp(r'[\p{L}\u200E\u200F\u061C]', unicode: true);

/// The direction of the first strong character in [text] (a letter or an
/// explicit direction mark), the rule HTML's `dir="auto"` uses, or null when
/// it has none.
TextDirection? firstStrongDirection(String text) {
  final strong = _strong.firstMatch(text);
  if (strong == null) return null;
  final rune = strong[0]!.runes.first;
  if (rune == 0x200E) return TextDirection.ltr;
  final rtl = rune == 0x200F ||
      rune == 0x061C ||
      (rune >= 0x0590 && rune <= 0x08FF) ||
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

  // In a right-to-left interface a body that starts in a left-to-right script
  // reads left to right, like dir="auto": an English README in Arabic. A
  // left-to-right interface is never flipped, because code blocks follow the
  // body's direction (flutter_markdown_plus has no per-block direction).
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
    final ambient = Directionality.of(context);
    final direction = ambient == TextDirection.rtl && _directionOf(text) == TextDirection.ltr
        ? TextDirection.ltr
        : ambient;
    return PageStorage(
      bucket: _scrollStorage,
      // Always wrapped, so a direction change keeps the subtree's state.
      child: Directionality(
        textDirection: direction,
        child: widget.selectable ? SelectionArea(child: body) : body,
      ),
    );
  }
}
