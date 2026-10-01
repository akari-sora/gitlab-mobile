import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/repository_ref.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'commit_page.dart';
import 'records_feed.dart';
import 'repository_page.dart';

/// Commits that touched one file on a ref, newest first.
class FileHistoryPage extends StatelessWidget {
  const FileHistoryPage({super.key, required this.account, required this.api, required this.project,
    required this.path, required this.ref});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String path, ref;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(titleSpacing: 0, title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
      children: [
        const Text('檔案歷史'),
        Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
      ])),
    body: gestureSafe(RecordsFeed(
      identity: '${project.id}/history/$ref/$path',
      account: account,
      resourceLabel: '${project.path} · $path',
      onSwitchAccount: endSessionFrom(context),
      empty: '沒有修改紀錄',
      emptyIcon: Icons.history,
      grouped: true,
      load: (next) => api.fileHistory(project.id, path, ref, next: next),
      itemBuilder: (context, value) => ListTile(
        minTileHeight: 60,
        leading: Monogram(valueText(value, 'author_name', '?'), size: 34),
        title: Text(valueText(value, 'title'), maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${valueText(value, 'short_id', shortSha(valueText(value, 'id')))} · '
          '${valueText(value, 'author_name')} · ${relativeDate(valueText(value, 'committed_date', valueText(value, 'created_at')))}'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommitDetailPage(
          account: account, api: api, project: project, sha: valueText(value, 'id'), initialCommit: value))),
      ),
    )),
  );
}

/// Who last changed each line, at one fixed commit.
class BlamePage extends StatefulWidget {
  const BlamePage({super.key, required this.account, required this.api, required this.project,
    required this.path, required this.sha});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String path, sha;
  @override
  State<BlamePage> createState() => _BlamePageState();
}

sealed class _BlameRow {}
final class _BlameHeader extends _BlameRow {
  _BlameHeader(this.commit);
  final Json commit;
}
final class _BlameLine extends _BlameRow {
  _BlameLine(this.number, this.text);
  final int number;
  final String text;
}

class _BlamePageState extends State<BlamePage> {
  List<_BlameRow> _rows = const [];
  int _longest = 0;
  ApiFailure? _error;
  bool _loading = true;
  final _horizontal = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final ranges = await widget.api.blame(widget.project.id, widget.path, widget.sha);
      final rows = <_BlameRow>[];
      var number = 0, longest = 0;
      for (final range in ranges) {
        rows.add(_BlameHeader(valueObject(range, 'commit')));
        final lines = range['lines'];
        if (lines is List) {
          for (final line in lines) {
            final text = line is String ? line : '';
            longest = math.max(longest, text.length);
            rows.add(_BlameLine(++number, text));
            if (number > GitLabApi.maxTextLines) throw const ApiFailure(FailureKind.tooLarge);
          }
        }
      }
      if (mounted) setState(() { _rows = rows; _longest = longest; });
    } catch (e) {
      if (mounted) setState(() => _error = safeFailure(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = codeTextStyle(context, fontSize: 12.5);
    final gutterWidth = '${_rows.whereType<_BlameLine>().length}'.length * 8.0 + 16;
    return Scaffold(
      appBar: AppBar(titleSpacing: 0, title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Blame'),
          Text('${widget.path} · ${shortSha(widget.sha)}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall),
        ])),
      body: gestureSafe(_error != null
        ? SingleChildScrollView(child: FailureNotice(_error!, onRetry: _load, account: widget.account,
            resourceLabel: '${widget.project.path} · ${widget.path}'))
        : _loading
          ? const ListSkeleton()
          : LayoutBuilder(builder: (context, constraints) {
              final width = math.max(constraints.maxWidth, gutterWidth + 24 + _longest * 7.6);
              return Scrollbar(controller: _horizontal, child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: width, child: ListView.builder(
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    switch (row) {
                      case _BlameHeader(:final commit):
                        final author = valueText(commit, 'author_name', '?');
                        return Material(
                          color: scheme.surfaceContainerHighest.withValues(alpha: .55),
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommitDetailPage(
                              account: widget.account, api: widget.api, project: widget.project,
                              sha: valueText(commit, 'id'), initialCommit: commit))),
                            child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), child: Row(children: [
                              Monogram(author, size: 22),
                              const SizedBox(width: 8),
                              Text(author, style: theme.textTheme.labelLarge),
                              const SizedBox(width: 8),
                              Text(shortSha(valueText(commit, 'id')), style: codeTextStyle(context, fontSize: 12,
                                color: scheme.primary)),
                              const SizedBox(width: 8),
                              Text(relativeDate(valueText(commit, 'authored_date', valueText(commit, 'committed_date'))),
                                style: theme.textTheme.bodySmall),
                              const SizedBox(width: 12),
                              Flexible(child: Text(valueText(commit, 'message').split('\n').first, maxLines: 1,
                                overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                            ])),
                          ),
                        );
                      case _BlameLine(:final number, :final text):
                        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(width: gutterWidth, child: Padding(padding: const EdgeInsets.only(right: 8),
                            child: Text('$number', textAlign: TextAlign.end,
                              style: code.copyWith(color: scheme.onSurfaceVariant)))),
                          Expanded(child: Text(text.isEmpty ? ' ' : text, style: code, softWrap: false)),
                        ]);
                    }
                  },
                )),
              ));
            })),
    );
  }
}

/// A path matches a lower-case query that is a substring of it, or whose
/// characters all appear in order, so `rpp` finds `repository_page.dart`.
bool findFileMatches(String path, String query) {
  final lower = path.toLowerCase();
  if (lower.contains(query)) return true;
  var at = 0;
  for (final unit in query.codeUnits) {
    at = lower.indexOf(String.fromCharCode(unit), at);
    if (at < 0) return false;
    at++;
  }
  return true;
}

/// Finds a file by name or path within one commit's tree.
class FindFilePage extends StatefulWidget {
  const FindFilePage({super.key, required this.account, required this.api, required this.project, required this.ref});
  final Account account;
  final GitLabApi api;
  final Project project;
  final RepositoryRef ref;
  @override
  State<FindFilePage> createState() => _FindFilePageState();
}

class _FindFilePageState extends State<FindFilePage> {
  static const _maxEntries = 6000;
  final _paths = <String>[];
  final _input = TextEditingController();
  ApiFailure? _error;
  bool _loading = true, _truncated = false;
  String _query = '';
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() { _loading = true; _error = null; _paths.clear(); _truncated = false; });
    Uri? next;
    try {
      do {
        final page = await widget.api.records(['projects', '${widget.project.id}', 'repository', 'tree'],
          query: {'ref': widget.ref.sha, 'recursive': 'true', 'per_page': '100'}, next: next);
        if (!mounted || epoch != _epoch) return;
        setState(() {
          _paths.addAll([
            for (final item in page.items)
              if (item['type'] == 'blob' && item['path'] is String) item['path'] as String,
          ]);
        });
        next = page.next;
        if (_paths.length >= _maxEntries && next != null) {
          setState(() => _truncated = true);
          break;
        }
      } while (next != null);
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = safeFailure(e));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.toLowerCase();
    final hits = query.isEmpty ? _paths.take(200).toList()
        : (_paths.where((path) => findFileMatches(path, query)).toList()
            ..sort((a, b) {
              final ai = a.toLowerCase().contains(query) ? 0 : 1, bi = b.toLowerCase().contains(query) ? 0 : 1;
              return ai != bi ? ai - bi : a.length - b.length;
            }));
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const Key('findFileField'),
          controller: _input,
          autofocus: true,
          decoration: InputDecoration(hintText: '尋找檔案 · ${widget.ref.name}', filled: false,
            border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none),
          onChanged: (value) => setState(() => _query = value.trim()),
        ),
      ),
      body: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
          resourceLabel: '${widget.project.path} · ${widget.ref.name}'),
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text(
          _truncated ? '已索引前 ${_paths.length} 個檔案（大型 repository 只搜尋前段）' : '${_paths.length} 個檔案',
          style: theme.textTheme.bodySmall)),
        Expanded(child: ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, index) {
            final path = hits[index];
            final slash = path.lastIndexOf('/');
            return ListTile(
              minTileHeight: 52,
              leading: Icon(fileIconFor(path), size: 20),
              title: Text(slash < 0 ? path : path.substring(slash + 1), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: slash < 0 ? null : Text(path.substring(0, slash), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => RepositoryFilePage(
                account: widget.account, api: widget.api, project: widget.project, ref: widget.ref, filePath: path))),
            );
          },
        )),
      ])),
    );
  }
}
