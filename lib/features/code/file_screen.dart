import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../auth/session_controller.dart';
import '../../shared/error_panel.dart';
import 'file_args.dart';

class FileScreen extends StatefulWidget {
  const FileScreen({super.key, required this.args, required this.session});
  final FileArgs args;
  final SessionController session;
  @override
  State<FileScreen> createState() => _FileScreenState();
}
class _FileScreenState extends State<FileScreen> {
  List<String>? lines;
  ApiFailure? error;
  bool wrap = true;
  bool lfs = false;
  int longest = 0;
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  @override
  void initState() { super.initState(); unawaited(_load()); }
  @override
  void dispose() { _vertical.dispose(); _horizontal.dispose(); super.dispose(); }
  Future<void> _load() async {
    setState(() { error = null; lines = null; });
    try {
      final a = widget.args;
      final text = await widget.session.api!.textFile(a.project.id, a.sha, a.path);
      if (!mounted) return;
      final result = text.split('\n');
      setState(() {
        lines = result;
        longest = result.fold(0, (previous, line) => math.max(previous, line.length));
        lfs = text.startsWith('version https://git-lfs.github.com/spec/v1');
      });
    } catch (e) { if (mounted) setState(() => error = safeFailure(e)); }
  }
  @override
  Widget build(BuildContext context) {
    final a = widget.args;
    return Scaffold(
      appBar: AppBar(title: Text(a.path.split('/').last), actions: [
        IconButton(tooltip: wrap ? '關閉自動換行' : '開啟自動換行', icon: Icon(wrap ? Icons.wrap_text : Icons.view_headline),
          onPressed: () => setState(() => wrap = !wrap)),
      ]),
      body: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(a.path), Text('${a.sha.substring(0, 8)} · 原始文字預覽'),
          if (lfs) const Text('這是 Git LFS pointer，不是實際大檔案。'),
          if (lines != null) Text('${lines!.length} 行 · 逐行選取；此版本未提供 Markdown 渲染'),
        ])),
        const Divider(height: 1),
        if (error != null) Expanded(child: SingleChildScrollView(child: ErrorPanel(
          failure: error!, account: widget.session.active, onRetry: () { unawaited(_load()); },
          onSwitchAccount: widget.session.endSession))),
        if (error == null && lines == null) const Expanded(child: Center(child: CircularProgressIndicator())),
        if (lines != null) Expanded(child: LayoutBuilder(builder: (context, constraints) {
          final fontSize = MediaQuery.textScalerOf(context).scale(14);
          final contentWidth = wrap ? constraints.maxWidth : math.max(constraints.maxWidth,
            math.min(24000.0, longest * fontSize * 0.65 + 80));
          return Directionality(textDirection: TextDirection.ltr, child: Scrollbar(
            controller: _horizontal, child: SingleChildScrollView(
              controller: _horizontal, scrollDirection: Axis.horizontal,
              physics: wrap ? const NeverScrollableScrollPhysics() : null,
              child: SizedBox(width: contentWidth, height: constraints.maxHeight,
                child: ListView.builder(controller: _vertical, itemCount: lines!.length,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemBuilder: (context, index) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 64, child: ExcludeSemantics(child: Text('${index + 1}', textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)))),
                      Expanded(child: Semantics(label: '第 ${index + 1} 行', child: SelectableText(
                        lines![index].isEmpty ? ' ' : lines![index],
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5),
                      ))),
                      const SizedBox(width: 16),
                    ])),
                )),
            ),
          ));
        })),
      ])),
    );
  }
}
