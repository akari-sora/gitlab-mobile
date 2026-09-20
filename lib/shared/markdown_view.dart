import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'external_link.dart';

class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {super.key, this.base});
  final String text;
  final Uri? base;
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
        code: TextStyle(fontFamily: 'monospace', fontSize: 13, color: Theme.of(context).colorScheme.onSurface),
        codeblockDecoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12)),
        blockquoteDecoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12)),
      ),
      // Untrusted Markdown must not fetch local files or authenticated images.
      // ignore: deprecated_member_use
      imageBuilder: (uri, title, alt) => Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.image_outlined, size: 18),
          const SizedBox(width: 6), Flexible(child: Text(alt?.isNotEmpty == true ? alt! : '附加圖片（在 GitLab 開啟）'))])),
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
