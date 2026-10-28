import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;

import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/offline/snapshot_reader.dart';
import '../core/repository_reader.dart';
import '../core/providers.dart';
import 'artifact_storage.dart';
import 'attachment_budget.dart';
import 'attachment_download.dart';
import 'attachment_image.dart';
import 'attachment_ref.dart';
import 'external_link.dart';
import 'in_app_links.dart';
import 'markdown_media.dart';
import 'markdown_media_source.dart';
import 'markdown_media_svg.dart';
import 'markdown_media_syntax.dart';
import 'network_boundary.dart';
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
final _underscoreStrong = RegExp(r'(?<![A-Za-z0-9_])__(?=[^\s_])((?:[^_]|_(?!_))*[^\s_])__(?![A-Za-z0-9_])');
final _escaped = RegExp(r'\\([!-/:-@\[-`{-~])');

/// GitLab's heading anchor for [text]: lower case, non-word characters
/// removed, spaces turned into hyphens and repeated hyphens collapsed.
String markdownHeadingSlug(String text) => text
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}_\- ]', unicode: true), '')
    .replaceAll(' ', '-')
    .replaceAll(RegExp(r'-{2,}'), '-');

/// Markdown read from an offline repository snapshot (§5.8, §6.6). Repository
/// images come only from the snapshot, through the reader and its media
/// policy; links that resolve to the same snapshot open locally. Outside the
/// snapshot nothing is fetched while the [NetworkBoundary] is offline.
final class SnapshotMarkdownContext {
  const SnapshotMarkdownContext({
    required this.reader,
    required this.projectPath,
    required this.refName,
    this.openPath,
  });

  /// The completed snapshot's reader; it owns the account and project fences.
  final SnapshotRepositoryReader reader;

  /// The project path and ref name the snapshot was saved with.
  final String projectPath, refName;

  /// Opens a path of the same snapshot (a folder or a file) in place.
  final void Function(String path)? openPath;
}

/// A code span stands in as U+FDD0, its index and U+FDD1 while a line's
/// links and tags are removed, so code inside a link label survives. These
/// noncharacters are removed from the text first, so none can collide.
final _noncharacters = RegExp(r'[\uFDD0-\uFDEF]');
final _codeMarker = RegExp(r'\uFDD0(\d+)\uFDD1');

/// How much of a description is scanned for its summary, in UTF-16 units.
const _summaryScanLimit = 32768;

/// The readable start of Markdown [source], for a one-paragraph summary.
/// Code keeps its text; HTML comments and tags, images, heading, quote,
/// fence and rule markers, bold and strike markers, code ticks and link
/// targets are dropped. `text` holds at most [limit] characters; `more`
/// tells whether readable text goes on past it. The work is bounded: at
/// most [_summaryScanLimit] units of [source] are read across all lines, so
/// syntax left open where the scan limit cuts a line can show.
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
({String text, bool inComment}) _readableLine(String source, {required bool Function(int offset) commentMayClose}) {
  final line = source.replaceAll(_noncharacters, '');
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
      out
        ..writeCharCode(0xFDD0)
        ..write(codes.length)
        ..writeCharCode(0xFDD1);
      codes.add(code);
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
    text = text.replaceAllMapped(_codeMarker, (match) => codes[int.parse(match[1]!)]);
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
    this.externalMediaClient,
    this.offline = false,
    this.snapshot,
  }) : assert(!(offline && snapshot != null));
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

  /// A separate bare client; tests inject a FakeAdapter here.
  final Dio? externalMediaClient;

  /// Text that is not the user's own content (an AI answer): images, SVG and
  /// media are never fetched, only named, and a link opens after the user
  /// has seen its full address and confirmed.
  final bool offline;

  /// Markdown from an offline snapshot; see [SnapshotMarkdownContext]. Not
  /// used together with [offline], whose AI behaviour stays unchanged.
  final SnapshotMarkdownContext? snapshot;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

typedef _MediaElementWidgetBuilder =
    Widget Function(
      Uri source,
      String kind,
      String? alt,
      String? width,
      String? height,
    );

final class _MarkdownMediaElementBuilder extends MarkdownElementBuilder {
  _MarkdownMediaElementBuilder({
    required this.buildMedia,
    required this.openLink,
  });

  final _MediaElementWidgetBuilder buildMedia;
  final Future<void> Function(String href) openLink;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final source = Uri.tryParse(element.attributes['src'] ?? '');
    if (source == null) return null;
    final child = buildMedia(
      source,
      element.attributes['kind'] ?? 'image',
      element.attributes['alt'],
      element.attributes['width'],
      element.attributes['height'],
    );
    final href = element.attributes['href'];
    if (href == null) return child;
    return GestureDetector(onTap: () => openLink(href), child: child);
  }
}

final class _MarkdownHtmlBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;
}

class _MarkdownViewState extends State<MarkdownView> {
  AttachmentBudget? _owned;
  MarkdownMediaLoader? _media;
  int _contentEpoch = 0;

  MarkdownMediaLoader get _loader => _media ??= MarkdownMediaLoader(
    api: widget.api,
    external: widget.externalMediaClient,
  );

  /// Reads repository images from the snapshot only; its external client
  /// refuses every request, so a missed path fails instead of connecting.
  MarkdownMediaLoader? _snapshotMedia;

  /// The style sheet of the last build, so an anchor can tell headings from
  /// body text with the same words.
  MarkdownStyleSheet? _styleSheet;
  MarkdownMediaLoader _snapshotLoader(SnapshotMarkdownContext snapshot) =>
      _snapshotMedia ??= MarkdownMediaLoader.snapshot(
        SnapshotReaderMediaSource(
          reader: snapshot.reader,
          projectPath: snapshot.projectPath,
          refName: snapshot.refName,
        ),
      );

  @override
  void dispose() {
    _media?.close();
    _snapshotMedia?.close();
    super.dispose();
  }

  // Markdown's unkeyed horizontal scroll views must not read an ancestor
  // ExpansionTile's boolean state as a scroll offset.
  final _scrollStorage = PageStorageBucket();

  AttachmentBudget get _budget =>
      widget.budget ?? (_owned ??= AttachmentBudget());

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
    if (oldWidget.projectId != widget.projectId ||
        oldWidget.api != widget.api ||
        oldWidget.base != widget.base ||
        oldWidget.projectWeb != widget.projectWeb ||
        oldWidget.account?.key != widget.account?.key ||
        oldWidget.externalMediaClient != widget.externalMediaClient ||
        !identical(oldWidget.snapshot?.reader, widget.snapshot?.reader)) {
      _contentEpoch++;
      _media?.close();
      _media = null;
      _snapshotMedia?.close();
      _snapshotMedia = null;
      _owned = AttachmentBudget();
    }
  }

  Future<void> _openLink(BuildContext context, String href) async {
    final parsed = Uri.tryParse(href);
    if (parsed == null) return;
    final snapshot = widget.snapshot;
    // An in-page anchor scrolls to its heading; nothing is opened (§5.8).
    if (snapshot != null && href.trimLeft().startsWith('#')) {
      _scrollToAnchor(href.trim().substring(1));
      return;
    }
    final base = widget.base;
    final uri = parsed.hasScheme ? parsed : base?.resolveUri(parsed);
    if (snapshot != null) {
      if (uri != null && await _openInSnapshot(snapshot, uri)) return;
      if (!context.mounted) return;
      if (NetworkBoundary.blocks(context)) {
        // Offline the address can only be copied: no browser, share or
        // download, and no in-app navigation that needs the API (§5.8).
        if (uri != null || parsed.hasScheme) {
          await _showOfflineLink(context, uri ?? parsed);
        }
        return;
      }
    }
    if (uri == null || !safeExternalUri(uri)) return;
    if (widget.offline && !await _confirmOpen(context, uri)) return;
    if (!context.mounted) return;
    final api = widget.api;
    final projectId = widget.projectId;
    final uploadRef = parseProjectUpload(
      uri,
      base: base,
      projectId: projectId,
      projectWeb: widget.projectWeb,
    );
    if (uploadRef != null && api != null && projectId != null) {
      Account? activeAccount = widget.account;
      if (activeAccount == null) {
        try {
          activeAccount = ProviderScope.containerOf(
            context,
            listen: false,
          ).read(sessionProvider).active;
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
  }

  /// Scrolls to the heading whose GitLab anchor is [fragment]; an unknown
  /// anchor does nothing.
  void _scrollToAnchor(String fragment) {
    String id;
    try {
      id = Uri.decodeComponent(fragment).toLowerCase();
    } on ArgumentError {
      return;
    }
    if (id.startsWith('user-content-')) id = id.substring(13);
    final headings = <({String tag, String text})>[];
    void walk(List<md.Node> nodes) {
      for (final node in nodes) {
        if (node is! md.Element) continue;
        if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
          final text = node.textContent.trim();
          if (text.isNotEmpty) headings.add((tag: node.tag, text: text));
        } else {
          walk(node.children ?? const []);
        }
      }
    }

    walk(
      md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
      ).parseLines(widget.text.split('\n')),
    );
    final seen = <String, int>{};
    int? target;
    for (var i = 0; i < headings.length; i++) {
      final slug = markdownHeadingSlug(headings[i].text);
      final count = seen[slug] ?? 0;
      seen[slug] = count + 1;
      if ((count == 0 ? slug : '$slug-$count') == id) {
        target = i;
        break;
      }
    }
    final sheet = _styleSheet;
    if (target == null || sheet == null || !mounted) return;
    // Rendered text is visited in document order and paired with the parsed
    // headings in order, so the n-th rendered heading is heading n: a link
    // with the same label (it has a recognizer) or a paragraph with the same
    // words (body size) is never taken for a heading, and a repeated heading
    // keeps its occurrence (`-1`, `-2`). A heading that cannot be matched
    // stops the pairing, so a wrong target is never chosen.
    var next = 0;
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is RichText) {
        if (next < headings.length &&
            _rendersHeading(widget.text, headings[next], sheet)) {
          if (next == target) {
            found = element;
            return;
          }
          next++;
        }
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    if (found case final element?) {
      unawaited(
        Scrollable.ensureVisible(
          element,
          duration: const Duration(milliseconds: 250),
          alignment: 0.05,
        ),
      );
    }
  }

  /// Whether [text] is the rendering of [heading]: the same words, no link,
  /// and the heading level's font size from [sheet].
  static bool _rendersHeading(
    InlineSpan text,
    ({String tag, String text}) heading,
    MarkdownStyleSheet sheet,
  ) {
    if (text.toPlainText().trim() != heading.text) return false;
    var link = false;
    double? size;
    text.visitChildren((span) {
      if (span is TextSpan) {
        if (span.recognizer != null) link = true;
        if (size == null && (span.text ?? '').isNotEmpty) {
          size = span.style?.fontSize;
        }
      }
      return true;
    });
    final expected = sheet.styles[heading.tag]?.fontSize;
    return !link && expected != null && size == expected;
  }

  /// The repository path [uri] points to inside this snapshot, or null. A
  /// link counts when it is on the account's instance, in the project the
  /// snapshot was saved from, at its ref name or SHA, and within its folder.
  String? _snapshotPath(SnapshotMarkdownContext snapshot, Uri uri) {
    final instance = widget.account?.instance ?? widget.api?.instance;
    if (instance == null || !instance.sameOrigin(uri)) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final prefix = instance.base.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < prefix.length + 4) return null;
    for (var i = 0; i < prefix.length; i++) {
      if (segments[i] != prefix[i]) return null;
    }
    final dash = segments.indexOf('-', prefix.length);
    if (dash < 0 || dash + 2 >= segments.length) return null;
    if (segments.sublist(prefix.length, dash).join('/') != snapshot.projectPath) {
      return null;
    }
    if (segments[dash + 1] != 'blob' && segments[dash + 1] != 'tree') {
      return null;
    }
    final owner = snapshot.reader.owner;
    final ref = segments[dash + 2];
    if (ref != owner.sha && ref != snapshot.refName) return null;
    final path = segments.sublist(dash + 3).join('/');
    final sub = owner.subPath;
    if (path.isEmpty) return sub.isEmpty ? '' : null;
    if (sub.isNotEmpty && path != sub && !path.startsWith('$sub/')) return null;
    return path;
  }

  /// Opens [uri] inside the snapshot when it names a folder or file there.
  Future<bool> _openInSnapshot(SnapshotMarkdownContext snapshot, Uri uri) async {
    final open = snapshot.openPath;
    final path = _snapshotPath(snapshot, uri);
    if (open == null || path == null) return false;
    if (path.isEmpty || path == snapshot.reader.owner.subPath) {
      open(path);
      return true;
    }
    try {
      final entry = await snapshot.reader.snapshotEntry(path);
      if (entry == null || !mounted) return false;
      open(path);
      return true;
    } on Object {
      return false;
    }
  }

  /// Offline, a link outside the snapshot can only be copied.
  Future<void> _showOfflineLink(BuildContext context, Uri uri) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              key: const ValueKey('snapshot-link-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.snapshotLinkTitle,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                // The full address, left to right in every language.
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(uri.toString()),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('snapshot-link-copy'),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: uri.toString()),
                      );
                      if (!sheetContext.mounted) return;
                      Navigator.of(sheetContext).pop();
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text(l10n.copiedLabel)),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(l10n.snapshotLinkCopy),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Future<bool> _confirmOpen(BuildContext context, Uri uri) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.markdownOpenLinkTitle),
        // The full address, left to right in every language.
        content: Directionality(
          textDirection: TextDirection.ltr,
          child: SelectableText(uri.toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.open),
          ),
        ],
      ),
    );
    return open ?? false;
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
    final budgetScope = (
      account: widget.account?.key,
      api: widget.api,
      external: widget.externalMediaClient,
      base: widget.base,
      projectId: widget.projectId,
      projectWeb: widget.projectWeb,
    );
    Widget buildMedia(
      Uri uri,
      String kind,
      String? alt,
      String? width,
      String? height,
    ) {
      if (widget.offline) {
        return _OfflineMedia(
          alt: alt,
          uri: uri,
          onOpen: () => _openLink(context, uri.toString()),
        );
      }
      final source = resolveMarkdownMedia(
        uri,
        base: base,
        instance: api?.instance ?? widget.account?.instance,
        projectId: projectId,
        projectWeb: projectWeb,
      );
      final snapshot = widget.snapshot;
      if (snapshot != null) {
        final image = kind != 'media' && kind != 'video' && kind != 'audio';
        if (image && source.kind == MarkdownMediaSourceKind.repository) {
          return _SnapshotImage(
            key: ValueKey(('snapshot-media', _contentEpoch, uri)),
            source: source,
            loader: _snapshotLoader(snapshot),
            reader: snapshot.reader,
            alt: alt,
          );
        }
        // Uploads, external, media and anything else are never fetched
        // offline; online they keep the ordinary behaviour below.
        if (NetworkBoundary.blocks(context) ||
            source.kind == MarkdownMediaSourceKind.repository) {
          return _SnapshotMediaPlaceholder(
            alt: alt,
            note: source.kind == MarkdownMediaSourceKind.repository
                ? l10n.snapshotMediaNotSaved
                : l10n.snapshotMediaOffline,
          );
        }
      }
        final extension = (source.filename ?? '').split('.').last.toLowerCase();
      final explicitMedia =
          kind == 'media' || kind == 'video' || kind == 'audio';
      final isMedia =
          explicitMedia ||
          const {
            'mp4',
            'webm',
            'mov',
            'm4v',
            'mp3',
            'm4a',
            'ogg',
            'wav',
          }.contains(extension);
        if (isMedia) {
        return MarkdownMediaCard(
          source: source,
          loader: _loader,
          account: widget.account,
          audio:
              kind == 'audio' ||
              (kind != 'video' &&
                  const {'mp3', 'm4a', 'ogg', 'wav'}.contains(extension)),
        );
        }
      double? dimension(String? value) {
        final parsed = value == null ? null : double.tryParse(value);
        return parsed != null && parsed.isFinite && parsed > 0
            ? parsed.clamp(1, 4096)
            : null;
        }

      final imageWidth = dimension(width);
      final imageHeight = dimension(height);
      final ref = parseProjectUpload(
        uri,
        base: base,
        projectId: projectId,
        projectWeb: projectWeb,
      );
        final client = api;
        final id = projectId;
      if (ref != null &&
          client != null &&
          id != null &&
            !ref.filename.toLowerCase().endsWith('.svg')) {
          final upload = AttachmentImage(
            api: client,
            budget: budget,
            projectId: id,
            secret: ref.secret,
            filename: ref.filename,
            alt: alt,
            projectWeb: projectWeb,
            projectPath: widget.projectPath,
          );
        return imageWidth == null && imageHeight == null
            ? upload
            : SizedBox(width: imageWidth, height: imageHeight, child: upload);
        }
      return MarkdownMediaImage(
        source: source,
        loader: _loader,
        budget: budget,
        budgetScope: budgetScope,
        account: widget.account,
        alt: alt,
        width: imageWidth,
        height: imageHeight,
            );
        }

    final body = MarkdownBody(
      key: ValueKey(_contentEpoch),
      data: text,
      selectable: false,
      blockSyntaxes: [MarkdownMediaBlockSyntax()],
      inlineSyntaxes: [
        MarkdownMediaImageSyntax(),
        MarkdownMediaInlineSyntax(),
        MarkdownMediaAutolinkSyntax(),
        MarkdownLiteralLessThanSyntax(),
        MarkdownMediaLinkSyntax(),
      ],
      builders: {
        markdownMediaElement: _MarkdownMediaElementBuilder(
          buildMedia: buildMedia,
          openLink: (href) => _openLink(context, href),
        ),
        markdownHtmlBlockElement: _MarkdownHtmlBlockBuilder(),
      },
      styleSheet: _styleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        h1: Theme.of(context).textTheme.headlineSmall,
        h2: Theme.of(context).textTheme.titleLarge,
        h3: Theme.of(context).textTheme.titleMedium,
        tableColumnWidth: FixedColumnWidth(180.0 * tableTextScale),
        tableScrollbarThumbVisibility: true,
        code: TextStyle(
          fontFamily: codeFontFamily,
          fontFamilyFallback: const ['Menlo', 'monospace'],
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        blockquoteDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      imageBuilder: (uri, title, alt) {
        return buildMedia(uri, 'image', alt, null, null);
      },
      onTapLink: (_, href, _) async {
        if (href != null) await _openLink(context, href);
      },
    );
    final ambient = Directionality.of(context);
    final direction =
        ambient == TextDirection.rtl && _directionOf(text) == TextDirection.ltr
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

/// Stands in for an image or media file that an offline view never fetches.
class _OfflineMedia extends StatelessWidget {
  const _OfflineMedia({
    required this.alt,
    required this.uri,
    required this.onOpen,
  });

  final String? alt;
  final Uri uri;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = (alt ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.image_not_supported_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label.isEmpty ? l10n.markdownOfflineMedia : label,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (label.isNotEmpty)
                        Text(
                          l10n.markdownOfflineMedia,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (uri.host.isNotEmpty)
                        Text(
                          uri.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.ltr,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A repository image read from the snapshot through its media policy.
/// Anything the policy refuses, or that was not saved, becomes a placeholder.
class _SnapshotImage extends StatefulWidget {
  const _SnapshotImage({
    super.key,
    required this.source,
    required this.loader,
    required this.reader,
    this.alt,
  });

  final MarkdownMediaSource source;
  final MarkdownMediaLoader loader;
  final SnapshotRepositoryReader reader;
  final String? alt;

  @override
  State<_SnapshotImage> createState() => _SnapshotImageState();
}

class _SnapshotImageState extends State<_SnapshotImage> {
  Uint8List? _bytes;
  bool _svg = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loader.load(widget.source);
      final svg = await sanitizeMarkdownSvg(
        bytes,
        contentType: (widget.source.path ?? '').toLowerCase().endsWith('.svg')
            ? 'image/svg+xml'
            : null,
      );
      widget.reader.checkCurrent();
      if (!mounted) return;
      setState(() {
        _bytes = svg ?? bytes;
        _svg = svg != null;
      });
    } on Object {
      final note = await _reason();
      if (mounted) setState(() => _note = note);
    }
  }

  /// "Not saved" only when the snapshot itself lacks this file; any other
  /// refusal (another project or ref, an upload) is not loaded offline.
  Future<String> _reason() async {
    final path = widget.source.path;
    final owner = widget.reader.owner;
    if (path == null ||
        widget.source.ref != owner.sha ||
        widget.source.project != '${owner.projectId}') {
      return l10n.snapshotMediaOffline;
    }
    try {
      final state = await widget.reader.entryState(path);
      return state == RepositoryEntryState.available
          ? l10n.snapshotMediaOffline
          : l10n.snapshotMediaNotSaved;
    } on Object {
      return l10n.snapshotMediaNotSaved;
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (note != null) {
      return _SnapshotMediaPlaceholder(alt: widget.alt, note: note);
    }
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(semanticsLabel: l10n.attachmentLoading),
      );
    }
    final fallback = _SnapshotMediaPlaceholder(
      alt: widget.alt,
      note: l10n.snapshotDamaged,
    );
    return ConstrainedBox(
      key: const ValueKey('snapshot-image'),
      constraints: const BoxConstraints(maxHeight: 480),
      child: _svg
          ? SvgPicture.memory(
              bytes,
              semanticsLabel: widget.alt,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => fallback,
            )
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              semanticLabel: widget.alt,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

/// Stands in for media that an offline snapshot view does not show.
class _SnapshotMediaPlaceholder extends StatelessWidget {
  const _SnapshotMediaPlaceholder({required this.alt, required this.note});

  final String? alt;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = (alt ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        key: const ValueKey('snapshot-media-placeholder'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (label.isNotEmpty)
                    Text(isolated(label), style: theme.textTheme.bodyMedium),
                  Text(
                    note,
                    style: (label.isEmpty
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.bodySmall)
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
