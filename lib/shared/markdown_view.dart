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
import 'theme.dart';

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

  AttachmentBudget get _budget => widget.budget ?? (_owned ??= AttachmentBudget());

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
      return const Text('內容超出 Markdown 排版上限（64 Ki 字元）。請改用原始文字或在 GitLab 開啟。');
    }
    final budget = _budget;
    final base = widget.base;
    final api = widget.api;
    final projectId = widget.projectId;
    final projectWeb = widget.projectWeb;
    final body = MarkdownBody(data: text, selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        h1: Theme.of(context).textTheme.headlineSmall,
        h2: Theme.of(context).textTheme.titleLarge,
        h3: Theme.of(context).textTheme.titleMedium,
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
        if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
            uri.queryParameters.keys.any((key) => const ['private_token', 'access_token', 'token', 'job_token'].contains(key.toLowerCase()))) {
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
        await openExternal(context, uri);
      },
    );
    if (!widget.selectable) {
      return body;
    }
    return SelectionArea(child: body);
  }
}
