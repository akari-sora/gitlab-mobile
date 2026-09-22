import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../core/gitlab_api.dart';
import 'attachment_image.dart';
import 'attachment_ref.dart';
import 'external_link.dart';
import 'theme.dart';

class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {super.key, this.base, this.api, this.projectId, this.projectWeb});
  final String text;
  final Uri? base;
  final GitLabApi? api;
  final int? projectId;
  final Uri? projectWeb;
  @override
  Widget build(BuildContext context) {
    if (text.length > 65536) {
      return const Text('內容超出 Markdown 排版上限（64 Ki 字元）。請改用原始文字或在 GitLab 開啟。');
    }
    return MarkdownBody(data: text, selectable: true,
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
      // ignore: deprecated_member_use
      imageBuilder: (uri, title, alt) {
        final ref = parseProjectUpload(uri, base: base, projectId: projectId, projectWeb: projectWeb);
        final client = api;
        final id = projectId;
        if (ref != null && client != null && id != null) {
          return AttachmentImage(api: client, projectId: id, secret: ref.secret, filename: ref.filename,
            alt: alt, projectWeb: projectWeb);
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
        await openExternal(context, uri);
      },
    );
  }
}
