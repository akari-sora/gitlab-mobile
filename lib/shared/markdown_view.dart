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

final _openingFence = RegExp(r'^[ \t]{0,3}(?:(`{3,})[^`]*|(~{3,}).*)$');
final _closingFence = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})[ \t]*$');
final _ruleOrUnderline = RegExp(r'^[ \t]{0,3}(?:(?:[-*_][ \t]*){3,}|=+[ \t]*)$');
final _blockPrefix = RegExp(r'^[ \t]{0,3}(?:>[ \t]?)*[ \t]*(?:#{1,6}(?:[ \t]+|$))?');
// Every pattern stops at the next bracket, underscore or angle bracket, so
// a line of thousands of `[` or `__x` is scanned in linear time.
final _htmlTag = RegExp(r'</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>');
// A destination may hold one level of parentheses: `(…/Foo_(bar))`.
final _image = RegExp(r'!\[[^\[\]]*\]\((?:[^()]|\([^()]*\))*\)');
final _link = RegExp(r'\[([^\[\]]*)\]\((?:[^()]|\([^()]*\))*\)');
final _strongOrStrike = RegExp(r'\*\*|~~');
final _underscoreStrong = RegExp(r'(?<![A-Za-z0-9_])__(?=[^\s_])([^_]*[^\s_])__(?![A-Za-z0-9_])');
final _escaped = RegExp(r'\\([!-/:-@\[-`{-~])');

/// Code spans stand in as Unicode noncharacters U+FDD0… while a line's
/// links and tags are removed, so code inside a link label survives.
const _codeMark = 0xFDD0, _codeMarks = 32;

/// How much of a description is scanned for its summary, in UTF-16 units.
const _summaryScanLimit = 32768;

/// The readable start of Markdown [source], for a one-paragraph summary.
/// Code keeps its text; HTML comments and tags, images, heading, quote,
/// fence and rule markers, bold and strike markers, code ticks and link
/// targets are dropped. `text` holds at most [limit] characters; `more`
/// tells whether readable text goes on past it. The work is bounded: at
/// most [_summaryScanLimit] units of [source] are read.
({String text, bool more}) markdownSummary(String source, int limit) {
  final out = StringBuffer();
  final lastClose = source.lastIndexOf('-->');
  String? fence;
  var inComment = false;
  var more = false;
  var start = 0;
  var budget = _summaryScanLimit;
  void write(String line) {
    if (out.isNotEmpty) out.write('\n');
    out.write(line);
  }
  while (start < source.length) {
    if (budget <= 0) {
      more = !inComment || lastClose >= start;
      break;
    }
    final newline = source.indexOf('\n', start);
    var end = newline < 0 ? source.length : newline;
    var cut = false;
    if (end - start > budget) {
      end = start + budget;
      // Never split a surrogate pair.
      if (end > start && (source.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
      cut = true;
    }
    var line = source.substring(start, end);
    var lineStart = start;
    budget -= end - start + 1;
    start = cut ? source.length : end + 1;
    final open = fence;
    if (open != null) {
      final close = _closingFence.firstMatch(line)?[1];
      if (close != null && close[0] == open[0] && close.length >= open.length) {
        fence = null;
      } else {
        write(line);
      }
    } else {
      if (inComment) {
        final close = line.indexOf('-->');
        if (close < 0) {
          if (cut) more = lastClose >= end;
          continue;
        }
        line = line.substring(close + 3);
        lineStart += close + 3;
        inComment = false;
      }
      final opening = _openingFence.firstMatch(line);
      if (opening != null) {
        fence = opening[1] ?? opening[2];
        continue;
      }
      if (_ruleOrUnderline.hasMatch(line)) continue;
      // Like an HTML block, a comment that starts the line runs until `-->`.
      final blockComment = line.trimLeft().startsWith('<!--');
      final body = line.replaceFirst(_blockPrefix, '');
      final bodyStart = lineStart + line.length - body.length;
      final readable = _readableLine(body,
          commentMayClose: (offset) => blockComment || lastClose >= bodyStart + offset + 4);
      inComment = readable.inComment;
      write(readable.text);
    }
    if (cut) {
      more = true;
      break;
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
/// as CommonMark does. A comment not closed on the line hides the rest only
/// if [commentMayClose] says a `-->` follows; otherwise it is plain text.
/// `inComment` is set when a comment runs past the line.
({String text, bool inComment}) _readableLine(String line, {required bool Function(int offset) commentMayClose}) {
  // Backtick runs, so each span finds its closing run without rescanning.
  final runs = <(int, int)>[];
  for (var i = 0; i < line.length;) {
    if (line.codeUnitAt(i) == 0x5C && i + 1 < line.length) {
      i += 2;
      continue;
    }
    if (line.codeUnitAt(i) != 0x60) {
      i++;
      continue;
    }
    var end = i;
    while (end < line.length && line.codeUnitAt(end) == 0x60) {
      end++;
    }
    runs.add((i, end - i));
    i = end;
  }
  final nextOfLength = <int, List<int>>{};
  for (var k = runs.length - 1; k >= 0; k--) {
    (nextOfLength[runs[k].$2] ??= <int>[]).add(k);
  }
  int? closingRun(int k) {
    final candidates = nextOfLength[runs[k].$2]!;
    while (candidates.isNotEmpty && candidates.last <= k) {
      candidates.removeLast();
    }
    return candidates.isEmpty ? null : candidates.last;
  }

  final lastCloseInLine = line.lastIndexOf('-->');
  final out = StringBuffer();
  final codes = <String>[];
  var plainStart = 0;
  var i = 0;
  var run = 0;
  var inComment = false;
  while (i < line.length) {
    while (run < runs.length && runs[run].$1 < i) {
      run++;
    }
    if (run < runs.length && runs[run].$1 == i) {
      final ticks = runs[run].$2;
      final close = closingRun(run);
      if (close == null) {
        i += ticks;
        run++;
        continue;
      }
      out.write(line.substring(plainStart, i));
      var code = line.substring(i + ticks, runs[close].$1);
      if (code.length > 1 && code.startsWith(' ') && code.endsWith(' ') && code.trim().isNotEmpty) {
        code = code.substring(1, code.length - 1);
      }
      if (codes.length < _codeMarks) {
        out.writeCharCode(_codeMark + codes.length);
        codes.add(code);
      } else {
        out.write(code);
      }
      i = runs[close].$1 + ticks;
      run = close + 1;
      plainStart = i;
      continue;
    }
    if (line.startsWith('<!--', i)) {
      // CommonMark 0.31: `<!-->` and `<!--->` are complete comments.
      final end = line.startsWith('>', i + 4)
          ? i + 5
          : line.startsWith('->', i + 4)
          ? i + 6
          : lastCloseInLine >= i + 4
          ? line.indexOf('-->', i + 4) + 3
          : null;
      if (end != null) {
        out.write(line.substring(plainStart, i));
        i = end;
        plainStart = i;
        continue;
      }
      if (commentMayClose(i)) {
        out.write(line.substring(plainStart, i));
        plainStart = line.length;
        inComment = true;
        break;
      }
    }
    i++;
  }
  if (!inComment) out.write(line.substring(plainStart));
  var text = out
      .toString()
      .replaceAll(_htmlTag, '')
      .replaceAll(_image, '')
      .replaceAllMapped(_link, (match) => match[1]!)
      .replaceAllMapped(_underscoreStrong, (match) => match[1]!)
      .replaceAll(_strongOrStrike, '')
      .replaceAllMapped(_escaped, (match) => match[1]!);
  if (codes.isNotEmpty) {
    text = String.fromCharCodes(text.runes.expand((rune) {
      final index = rune - _codeMark;
      return index >= 0 && index < codes.length ? codes[index].runes : [rune];
    }));
  }
  return (text: text, inComment: inComment);
}

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
