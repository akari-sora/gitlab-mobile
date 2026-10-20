import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/failure.dart';
import '../../core/unified_diff.dart';
import '../../shared/attachment_budget.dart';
import '../../shared/external_link.dart';
import '../../shared/resource_share.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import '../../shared/theme.dart';
import '../../core/suggestion.dart';
import 'draft_review_page.dart';
import 'suggestion_card.dart';

import '../../l10n/l10n.dart';
typedef DiffParser = Future<List<DiffLine>> Function(String source);

const _asyncDiffParseThreshold = 64 * 1024;
const _maxDiffSourceBytes = 2 * 1024 * 1024;
const _maxParsedDiffTextBytes = 2 * 1024 * 1024;
const _maxParsedDiffLines = 20000;
const _maxDiffCacheEntries = 24;
const _maxDiffCacheBytes = 8 * 1024 * 1024;
const _maxDiffCacheLines = 40000;
const _estimatedDiffLineOverhead = 64;

typedef _DiffCacheScope = ({
  String accountKey,
  int projectId,
  int iid,
  String headSha,
  String path,
});

Future<List<DiffLine>> _defaultDiffParser(String source) {
  if (utf8.encode(source).length < _asyncDiffParseThreshold) {
    return SynchronousFuture(parseUnifiedDiff(source));
  }
  return compute(parseUnifiedDiff, source);
}

final class _DiffCacheEntry {
  const _DiffCacheEntry({
    required this.scope,
    required this.source,
    required this.lines,
    required this.estimatedBytes,
  });

  final _DiffCacheScope scope;
  final String source;
  final List<DiffLine> lines;
  final int estimatedBytes;
}

final class _DiffCache {
  final Map<_DiffCacheScope, _DiffCacheEntry> _entries = {};
  int _estimatedBytes = 0;
  int _parsedLines = 0;

  List<DiffLine>? take(_DiffCacheScope scope, String source) {
    final entry = _entries[scope];
    if (entry == null) return null;
    if (entry.source != source) {
      _remove(scope);
      return null;
    }
    _remove(scope);
    _entries[scope] = entry;
    _estimatedBytes += entry.estimatedBytes;
    _parsedLines += entry.lines.length;
    return entry.lines;
  }

  void put(_DiffCacheEntry entry) {
    _remove(entry.scope);
    if (entry.estimatedBytes > _maxDiffCacheBytes ||
        entry.lines.length > _maxDiffCacheLines) {
      return;
    }
    while (_entries.isNotEmpty &&
        (_entries.length >= _maxDiffCacheEntries ||
            _estimatedBytes + entry.estimatedBytes > _maxDiffCacheBytes ||
            _parsedLines + entry.lines.length > _maxDiffCacheLines)) {
      _remove(_entries.keys.first);
    }
    _entries[entry.scope] = entry;
    _estimatedBytes += entry.estimatedBytes;
    _parsedLines += entry.lines.length;
  }

  void _remove(_DiffCacheScope scope) {
    final removed = _entries.remove(scope);
    if (removed == null) return;
    _estimatedBytes -= removed.estimatedBytes;
    _parsedLines -= removed.lines.length;
  }
}

final _diffCacheExpando = Expando<_DiffCache>('diffCache');

_DiffCache _getDiffCache(GitLabApi api) {
  return _diffCacheExpando[api] ??= _DiffCache();
}

const _maxDiscussionPages = 20;
String get _discussionPageBoundNote => l10n.discussionsPageLimit;

/// A file and line taken from a real discussion position. Never invented.
class DiffTarget {
  const DiffTarget({
    required this.path,
    this.oldPath = '',
    this.newPath = '',
    this.newLine,
    this.oldLine,
    this.baseSha = '',
    this.startSha = '',
    this.headSha = '',
  });
  final String path;
  final String oldPath;
  final String newPath;
  final int? newLine;
  final int? oldLine;
  final String baseSha;
  final String startSha;
  final String headSha;
}

final class _DiscussionLoad {
  const _DiscussionLoad(
    this.items, {
    this.truncated = false,
    this.error,
    this.next,
  });
  final List<Json> items;
  final bool truncated;
  final ApiFailure? error;

  /// Cursor that failed, so a retry can fetch the rest without dropping [items].
  final Uri? next;
}

final class _DiscussionFeed {
  const _DiscussionFeed({
    this.items = const [],
    this.truncated = false,
    this.error,
    this.next,
    this.loading = false,
  });
  final List<Json> items;
  final bool truncated;
  final ApiFailure? error;
  final Uri? next;
  final bool loading;
}

Future<_DiscussionLoad> _loadDiscussions(
  GitLabApi api,
  List<String> path, {
  required int epoch,
  required bool Function(int epoch) current,
  Uri? resume,
}) async {
  final items = <Json>[];
  var next = resume;
  var pages = 0;
  try {
    while (true) {
      if (!current(epoch)) return _DiscussionLoad(items, next: next);
      final page = await api.records([...path, 'discussions'], next: next);
      if (!current(epoch)) return _DiscussionLoad(items, next: next);
      items.addAll(page.items);
      pages++;
      final cursor = page.next;
      if (cursor == null) return _DiscussionLoad(items);
      if (pages >= _maxDiscussionPages) {
        return _DiscussionLoad(items, truncated: true);
      }
      next = cursor;
    }
  } catch (e) {
    return _DiscussionLoad(items, error: safeFailure(e), next: next);
  }
}

Json? _textPosition(Json discussion) {
  final notes = valueObjects(discussion, 'notes');
  if (notes.isEmpty) return null;
  final position = notes.first['position'];
  if (position is! Json || position['position_type'] != 'text') return null;
  return position;
}

bool _shasMatch(Json position, Json version) {
  final base = position['base_sha'];
  final start = position['start_sha'];
  final head = position['head_sha'];
  return base is String &&
      base.isNotEmpty &&
      base == version['base_commit_sha'] &&
      start is String &&
      start.isNotEmpty &&
      start == version['start_commit_sha'] &&
      head is String &&
      head.isNotEmpty &&
      head == version['head_commit_sha'];
}

bool _positiveLine(Object? value) => value is int && value > 0;

/// The line coordinates of a text position, or null when a supplied
/// `new_line` / `old_line` is not a positive int. Inline anchoring and
/// 查看程式碼 navigation share this rule, so a half-malformed position can
/// never anchor on its valid half.
({int? newLine, int? oldLine})? diffPositionLines(Json position) {
  final newLine = position['new_line'];
  final oldLine = position['old_line'];
  if (newLine != null && !_positiveLine(newLine)) return null;
  if (oldLine != null && !_positiveLine(oldLine)) return null;
  return (newLine: newLine as int?, oldLine: oldLine as int?);
}

/// A line anchor needs a real file identity and only positive integer
/// coordinates. A missing path, or a supplied coordinate that is not a
/// positive int, must not attach the thread to whatever row shares a number.
bool _mapsToLine(Json position, Json file, DiffLine line) {
  final lines = diffPositionLines(position);
  if (lines == null) return false;
  final newLine = lines.newLine;
  final oldLine = lines.oldLine;
  final newPath = position['new_path'];
  final oldPath = position['old_path'];
  final fileNew = valueText(file, 'new_path');
  final fileOld = valueText(file, 'old_path');
  final newSupplied = newPath is String && newPath.isNotEmpty;
  final oldSupplied = oldPath is String && oldPath.isNotEmpty;
  if (!newSupplied && !oldSupplied) return false;
  if (newSupplied && newPath != fileNew) return false;
  if (oldSupplied && oldPath != fileOld) return false;
  if (newLine == null && oldLine == null) return false;
  if (newLine != null && line.newLine != newLine) return false;
  if (oldLine != null && line.oldLine != oldLine) return false;
  return true;
}

/// new_path is compared only with the file's new_path, old_path only with old_path.
bool _positionClaimsFile(Json position, Json file) {
  final fileNew = valueText(file, 'new_path');
  final fileOld = valueText(file, 'old_path');
  final newPath = position['new_path'];
  final oldPath = position['old_path'];
  final newSupplied = newPath is String && newPath.isNotEmpty;
  final oldSupplied = oldPath is String && oldPath.isNotEmpty;
  if (!newSupplied && !oldSupplied) return false;
  if (newSupplied && newPath != fileNew) return false;
  if (oldSupplied && oldPath != fileOld) return false;
  return true;
}

String _unplacedReason(Json position, Json version) =>
    _shasMatch(position, version)
    ? l10n.diffLineUnavailable
    : l10n.discussionOnOlderDiff;

Json _targetPosition(DiffTarget target) {
  final position = <String, dynamic>{};
  if (target.newPath.isNotEmpty) {
    position['new_path'] = target.newPath;
  } else if (target.oldPath.isEmpty &&
      target.newLine != null &&
      target.path.isNotEmpty) {
    position['new_path'] = target.path;
  }
  if (target.oldPath.isNotEmpty) {
    position['old_path'] = target.oldPath;
  } else if (target.newPath.isEmpty &&
      target.oldLine != null &&
      target.path.isNotEmpty) {
    position['old_path'] = target.path;
  }
  if (target.newLine != null) position['new_line'] = target.newLine;
  if (target.oldLine != null) position['old_line'] = target.oldLine;
  return position;
}

String _positionPath(Json position) {
  final newPath = position['new_path'];
  if (newPath is String && newPath.isNotEmpty) return newPath;
  final oldPath = position['old_path'];
  if (oldPath is String) return oldPath;
  return '';
}

String diffFilePath(Json file) {
  final newPath = valueText(file, 'new_path');
  if (newPath.isNotEmpty) return newPath;
  final oldPath = valueText(file, 'old_path');
  if (oldPath.isNotEmpty) return oldPath;
  return l10n.unnamedFile;
}

String _positionLines(Json position) {
  final parts = <String>[];
  final newLine = position['new_line'];
  final oldLine = position['old_line'];
  if (newLine is int) parts.add(l10n.newDiffLine(newLine));
  if (oldLine is int) parts.add(l10n.oldDiffLine(oldLine));
  return parts.join(' · ');
}

String _excerpt(String body) {
  final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= 180) return flat;
  return '${flat.substring(0, 180)}…';
}

class ReviewDiffPage extends StatefulWidget {
  const ReviewDiffPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.iid,
    required this.expectedSha,
    this.initialTarget,
    this.onApplied,
    this.diffParser,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final String expectedSha;
  final DiffTarget? initialTarget;
  final VoidCallback? onApplied;
  final DiffParser? diffParser;
  @override
  State<ReviewDiffPage> createState() => _ReviewDiffPageState();
}

class _ReviewDiffPageState extends State<ReviewDiffPage> {
  Json? _version;
  ApiFailure? _error;
  ApiFailure? _discussionsError;
  bool _loading = true;
  bool _discussionsTruncated = false;
  bool _openedTarget = false;
  int _epoch = 0;
  List<Json> _discussions = const [];
  Uri? _discussionNext;
  bool _discussionsLoading = true;
  final _feed = ValueNotifier<_DiscussionFeed>(
    const _DiscussionFeed(loading: true),
  );
  final _orphanKey = GlobalKey();
  final Set<String> _viewedFiles = <String>{};
  List<String> get path => [
    'projects',
    '${widget.project.id}',
    'merge_requests',
    '${widget.iid}',
  ];
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<Json> _fetchVersion() async {
    final versions = await widget.api.records([...path, 'versions']);
    final matches = versions.items.where(
      (value) => value['head_commit_sha'] == widget.expectedSha,
    );
    if (matches.isEmpty) {
      throw const ApiFailure(FailureKind.conflict);
    }
    final version = await widget.api.record([
      ...path,
      'versions',
      '${requiredInt(matches.first, 'id')}',
    ]);
    if (version['head_commit_sha'] != widget.expectedSha) {
      throw const ApiFailure(FailureKind.conflict);
    }
    return version;
  }

  bool _walkCurrent(int epoch) => mounted && epoch == _epoch;

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  void _publishFeed({required bool loading}) {
    _discussionsLoading = loading;
    _feed.value = _DiscussionFeed(
      items: _discussions,
      truncated: _discussionsTruncated,
      error: _discussionsError,
      next: _discussionNext,
      loading: loading,
    );
  }

  void _takeDiscussions(_DiscussionLoad loaded) {
    if (loaded.items.isNotEmpty || loaded.error == null) {
      _discussions = loaded.items;
      _discussionsTruncated = loaded.truncated;
    }
    _discussionsError = loaded.error;
    _discussionNext = loaded.next;
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
      _discussionsError = null;
      _discussionsLoading = true;
    });
    _publishFeed(loading: true);
    final discussionsFuture = _loadDiscussions(
      widget.api,
      path,
      epoch: epoch,
      current: _walkCurrent,
    );
    try {
      final version = await _fetchVersion();
      if (!mounted || epoch != _epoch) {
        await discussionsFuture;
        return;
      }
      setState(() {
        _version = version;
        final currentPaths = valueObjects(
          version,
          'diffs',
        ).map(diffFilePath).toSet();
        _viewedFiles.retainAll(currentPaths);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _epoch) {
        await discussionsFuture;
        return;
      }
      setState(() {
        _error = safeFailure(e);
        _loading = false;
      });
    }
    final loaded = await discussionsFuture;
    if (!mounted || epoch != _epoch) return;
    _takeDiscussions(loaded);
    setState(() {});
    _publishFeed(loading: false);
    if (_error == null) _scheduleInitialTarget();
  }

  Future<void> _refreshDiscussions() async {
    final epoch = ++_epoch;
    final loaded = await _loadDiscussions(
      widget.api,
      path,
      epoch: epoch,
      current: _walkCurrent,
    );
    if (!mounted || epoch != _epoch) return;
    _takeDiscussions(loaded);
    setState(() {});
    _publishFeed(loading: false);
  }

  Json? _fileFor(DiffTarget target) {
    final version = _version;
    if (version == null) return null;
    for (final file in valueObjects(version, 'diffs')) {
      if (_targetNamesFile(target, file)) return file;
    }
    return null;
  }

  bool _targetNamesFile(DiffTarget target, Json file) {
    final fileNew = valueText(file, 'new_path');
    final fileOld = valueText(file, 'old_path');
    if (target.newPath.isNotEmpty || target.oldPath.isNotEmpty) {
      final newOk = target.newPath.isEmpty || target.newPath == fileNew;
      final oldOk = target.oldPath.isEmpty || target.oldPath == fileOld;
      final mentioned =
          (target.newPath.isNotEmpty && target.newPath == fileNew) ||
          (target.oldPath.isNotEmpty && target.oldPath == fileOld);
      return mentioned && newOk && oldOk;
    }
    if (target.path.isEmpty) return false;
    return target.path == fileNew || target.path == fileOld;
  }

  void _scheduleInitialTarget() {
    final target = widget.initialTarget;
    if (target == null || _openedTarget || _version == null) return;
    final file = _fileFor(target);
    if (file == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final orphan = _orphanKey.currentContext;
        if (orphan != null) {
          unawaited(Scrollable.ensureVisible(orphan, alignment: 0.05));
        }
      });
      return;
    }
    _openedTarget = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open(file, target: target));
    });
  }

  List<Json> _unmatchedDiscussions() {
    final files = valueObjects(_version ?? const <String, dynamic>{}, 'diffs');
    final claimed = <Json>{};
    for (final file in files) {
      for (final discussion in _discussions) {
        final position = _textPosition(discussion);
        if (position != null && _positionClaimsFile(position, file)) {
          claimed.add(discussion);
        }
      }
    }
    return [
      for (final discussion in _discussions)
        if (!claimed.contains(discussion) && _textPosition(discussion) != null)
          discussion,
    ];
  }

  int _unresolvedCountForFile(Json file) {
    var count = 0;
    for (final discussion in _discussions) {
      final pos = _textPosition(discussion);
      if (pos != null && _positionClaimsFile(pos, file)) {
        if (!_resolved(discussion)) count++;
      }
    }
    return count;
  }

  String _targetReason(DiffTarget target) {
    final version = _version;
    if (version == null) return l10n.discussionOnOlderDiff;
    return _unplacedReason({
      'base_sha': target.baseSha,
      'start_sha': target.startSha,
      'head_sha': target.headSha,
    }, version);
  }

  Future<void> _open(Json file, {DiffTarget? target}) async {
    final version = _version;
    if (version == null) return;
    final filePath = diffFilePath(file);
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _DiffFileScreen(
          account: widget.account,
          api: widget.api,
          project: widget.project,
          iid: widget.iid,
          file: file,
          version: version,
          feed: _feed,
          initialTarget: target,
          isViewed: _viewedFiles.contains(filePath),
          onToggleViewed: () {
            setState(() {
              if (_viewedFiles.contains(filePath)) {
                _viewedFiles.remove(filePath);
              } else {
                _viewedFiles.add(filePath);
              }
            });
          },
          onApplied: widget.onApplied,
          diffParser: widget.diffParser,
        ),
      ),
    );
    if (!mounted) return;
    await _refreshDiscussions();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ListSkeleton();
    }
    if (_error != null) {
      return ListView(
        children: [
          FailureNotice(
            _error!,
            onRetry: _load,
            account: widget.account,
            resourceLabel: l10n.mergeRequestDiffTitle(widget.project.path, widget.iid),
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }
    final files = valueObjects(_version ?? {}, 'diffs');
    final target = widget.initialTarget;
    final missingTarget = target != null && _fileFor(target) == null;
    final unmatched = _unmatchedDiscussions();
    final filePaths = files.map(diffFilePath).toSet();
    final viewedCount = files
        .where((f) => _viewedFiles.contains(diffFilePath(f)))
        .length;
    final allViewed = files.isNotEmpty && viewedCount == files.length;
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              files.isEmpty && unmatched.isEmpty && !missingTarget ? 16 : 0,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.pinnedDiffVersion(shortSha(widget.expectedSha)),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_version?['overflow'] == true)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(l10n.partialDiffNotComplete),
                    ),
                  if (_discussionsLoading)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(l10n.loadingDiscussions),
                    ),
                  if (_discussionsTruncated)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(_discussionPageBoundNote),
                    ),
                  if (_discussionsError != null)
                    FailureNotice(
                      _discussionsError!,
                      onRetry: _load,
                      account: widget.account,
                      resourceLabel:
                          l10n.mergeRequestThreadsTitle(widget.project.path, widget.iid),
                      onSwitchAccount: endSessionFrom(context),
                    ),
                  if (files.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Card(
                        elevation: 0,
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final summary = Row(
                                    children: [
                                      Icon(
                                        allViewed
                                            ? Icons.check_circle
                                            : Icons.rule_folder_outlined,
                                        size: 18,
                                        color: allViewed
                                            ? Colors.green
                                            : Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          l10n.reviewProgress(viewedCount, files.length),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                    ],
                                  );
                                  final action = TextButton(
                                    key: const ValueKey('toggle-all-viewed'),
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(48, 48),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        if (allViewed) {
                                          _viewedFiles.removeAll(filePaths);
                                        } else {
                                          _viewedFiles.addAll(filePaths);
                                        }
                                      });
                                    },
                                    child: Text(allViewed ? l10n.unmarkAllViewed : l10n.markAllAsViewed),
                                  );
                                  final compact =
                                      constraints.maxWidth < 420 ||
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(1) >
                                          1.3;
                                  if (compact) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        summary,
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: action,
                                        ),
                                      ],
                                    );
                                  }
                                  return Row(
                                    children: [
                                      Expanded(child: summary),
                                      action,
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: files.isEmpty
                                      ? 0
                                      : (viewedCount / files.length).clamp(
                                          0.0,
                                          1.0,
                                        ),
                                  minHeight: 4,
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    allViewed
                                        ? Colors.green
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (files.isEmpty)
                    EmptyState(
                      l10n.noTextDiffToDisplay,
                      detail: l10n.diffMissingOrNoChanges,
                    ),
                ],
              ),
            ),
          ),
          if (files.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                unmatched.isEmpty && !missingTarget ? 16 : 0,
              ),
              sliver: SliverList.builder(
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final file = files[index];
                  final filePath = diffFilePath(file);
                  final isViewed = _viewedFiles.contains(filePath);
                  final fileUnresolved = _unresolvedCountForFile(file);
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Card(
                      child: ListTile(
                        leading: Icon(
                          file['new_file'] == true
                              ? Icons.add_box_outlined
                              : file['deleted_file'] == true
                              ? Icons.indeterminate_check_box_outlined
                              : Icons.code,
                          color: isViewed
                              ? Theme.of(context).colorScheme.outline
                              : null,
                        ),
                        title: Text(
                          filePath,
                          style: isViewed
                              ? TextStyle(
                                  color: Theme.of(context).colorScheme.outline,
                                )
                              : null,
                        ),
                        subtitle: file['renamed_file'] == true
                            ? Text(l10n.originalFilePath(valueText(file, 'old_path')))
                            : (isViewed
                                  ? Text(
                                      l10n.fileViewed,
                                      style: TextStyle(
                                        color: Colors.green,
                                        fontSize: 12,
                                      ),
                                    )
                                  : null),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (fileUnresolved > 0)
                              Container(
                                key: ValueKey(
                                  'file-unresolved-badge-$filePath',
                                ),
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '$fileUnresolved',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            IconButton(
                              key: ValueKey('viewed-toggle-$filePath'),
                              icon: Icon(
                                isViewed
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 22,
                                color: isViewed
                                    ? Colors.green
                                    : Theme.of(context).colorScheme.outline,
                              ),
                              tooltip: isViewed ? l10n.markAsNotViewed : l10n.markAsViewed,
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              onPressed: () {
                                setState(() {
                                  if (isViewed) {
                                    _viewedFiles.remove(filePath);
                                  } else {
                                    _viewedFiles.add(filePath);
                                  }
                                });
                              },
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ),
                        onTap: () => _open(file),
                      ),
                    ),
                  );
                },
              ),
            ),
          if (unmatched.isNotEmpty || missingTarget)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              sliver: SliverToBoxAdapter(
                child: _OtherVersionSection(
                  key: _orphanKey,
                  version: _version ?? const <String, dynamic>{},
                  discussions: unmatched,
                  fallbackPath: missingTarget ? target.path : '',
                  fallbackNewLine: missingTarget ? target.newLine : null,
                  fallbackOldLine: missingTarget ? target.oldLine : null,
                  fallbackReason: missingTarget
                      ? _targetReason(target)
                      : l10n.discussionOnOlderDiff,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiffFileScreen extends StatefulWidget {
  const _DiffFileScreen({
    required this.account,
    required this.api,
    required this.project,
    required this.iid,
    required this.file,
    required this.version,
    required this.feed,
    this.initialTarget,
    this.isViewed = false,
    this.onToggleViewed,
    this.onApplied,
    this.diffParser,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final Json file;
  final Json version;
  final ValueNotifier<_DiscussionFeed> feed;
  final DiffTarget? initialTarget;
  final bool isViewed;
  final VoidCallback? onToggleViewed;
  final VoidCallback? onApplied;
  final DiffParser? diffParser;
  @override
  State<_DiffFileScreen> createState() => _DiffFileScreenState();
}

class _DiffFileScreenState extends State<_DiffFileScreen> {
  List<DiffLine>? _lines;
  String? _unavailable;
  ApiFailure? _diffError;
  bool _diffLoading = false;
  late List<Json> _discussions;
  late bool _truncated;
  late bool _viewed;
  ApiFailure? _discussionsError;
  bool _reloading = false;
  bool _busy = false;
  bool _disposed = false;
  bool _discussionsLoading = false;
  bool _ignoreParentFeed = false;
  int _epoch = 0;
  var _revealScheduled = false;
  var _seekLow = 0.0;
  var _seekHigh = -1.0;
  var _seekStall = 0;
  final _builtLines = <int>{};
  final _expanded = <String>{};
  final _attachments = AttachmentBudget();
  final _scroll = ScrollController();
  final _targetKey = GlobalKey();
  final _navTargetKey = GlobalKey();
  int? _activeDiscussionTargetIndex;
  List<String> get _mrPath => [
    'projects',
    '${widget.project.id}',
    'merge_requests',
    '${widget.iid}',
  ];

  _DiffCacheScope get _cacheScope => (
    accountKey: widget.account.key,
    projectId: widget.project.id,
    iid: widget.iid,
    headSha: valueText(widget.version, 'head_commit_sha'),
    path: diffFilePath(widget.file),
  );

  int _parsedTextBytes(List<DiffLine> lines) {
    var bytes = 0;
    for (final line in lines) {
      bytes += utf8.encode(line.text).length;
      if (bytes > _maxParsedDiffTextBytes) {
        throw const FormatException('Parsed diff text budget exceeded');
      }
    }
    return bytes;
  }

  @override
  void initState() {
    super.initState();
    _viewed = widget.isViewed;
    _applyFeed(widget.feed.value);
    widget.feed.addListener(_onFeed);
    _initDiff();
  }

  void _initDiff() {
    _lines = null;
    _diffError = null;
    _unavailable = null;
    _seekLow = 0;
    _seekHigh = -1;
    _seekStall = 0;
    _builtLines.clear();
    _activeDiscussionTargetIndex = null;
    _navSeekStall = 0;
    final diff = valueText(widget.file, 'diff');
    if (widget.file['too_large'] == true ||
        widget.file['collapsed'] == true ||
        diff.isEmpty) {
      _unavailable = l10n.textDiffUnavailableOrBinary;
      _diffLoading = false;
      if (widget.initialTarget != null) {
        _scheduleReveal();
      }
      return;
    }

    final int? sourceBytes = diff.length > _maxDiffSourceBytes
        ? null
        : utf8.encode(diff).length;
    if (sourceBytes == null || sourceBytes > _maxDiffSourceBytes) {
      _unavailable = l10n.inlineCommentsDisabled;
      _diffLoading = false;
      if (widget.initialTarget != null) {
        _scheduleReveal();
      }
      return;
    }

    final useSharedCache = widget.diffParser == null;
    final cacheScope = _cacheScope;
    if (useSharedCache && !widget.api.isClosed) {
      final cache = _getDiffCache(widget.api);
      final cached = cache.take(cacheScope, diff);
      if (cached != null) {
        _lines = cached;
        _diffLoading = false;
        if (widget.initialTarget != null) {
          _scheduleReveal();
        }
        return;
      }
    }

    _diffLoading = true;
    unawaited(
      _parse(
        diff,
        cacheScope: cacheScope,
        sourceBytes: sourceBytes,
        useSharedCache: useSharedCache,
      ),
    );
  }

  Future<void> _parse(
    String diff, {
    required _DiffCacheScope cacheScope,
    required int sourceBytes,
    required bool useSharedCache,
  }) async {
    final epoch = ++_epoch;
    try {
      final parser = widget.diffParser ?? _defaultDiffParser;
      final parsed = await parser(diff);
      if (!mounted || _disposed || epoch != _epoch || widget.api.isClosed) {
        return;
      }
      if (parsed.length > _maxParsedDiffLines) {
        throw const FormatException('Parsed diff line budget exceeded');
      }
      final lines = List<DiffLine>.unmodifiable(parsed);
      final parsedTextBytes = _parsedTextBytes(lines);
      // This is a conservative retained-heap estimate, not measured RAM:
      // exact UTF-8 source + parsed UTF-8 text + per-row object/reference cost.
      final estimatedBytes =
          sourceBytes +
          parsedTextBytes +
          lines.length * _estimatedDiffLineOverhead;
      if (!mounted || _disposed || epoch != _epoch || widget.api.isClosed) {
        return;
      }
      if (useSharedCache) {
        _getDiffCache(widget.api).put(
          _DiffCacheEntry(
            scope: cacheScope,
            source: diff,
            lines: lines,
            estimatedBytes: estimatedBytes,
          ),
        );
      }
      setState(() {
        _lines = lines;
        _diffLoading = false;
        _seekLow = 0;
        _seekHigh = -1;
        _seekStall = 0;
      });
      if (widget.initialTarget != null) {
        _scheduleReveal();
      }
    } on FormatException {
      if (!mounted || _disposed || epoch != _epoch || widget.api.isClosed) {
        return;
      }
      setState(() {
        _unavailable = l10n.inlineCommentsDisabled;
        _diffLoading = false;
      });
      if (widget.initialTarget != null) {
        _scheduleReveal();
      }
    } catch (e) {
      if (!mounted || _disposed || epoch != _epoch || widget.api.isClosed) {
        return;
      }
      setState(() {
        _diffError = safeFailure(e);
        _diffLoading = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _DiffFileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isViewed != oldWidget.isViewed) {
      _viewed = widget.isViewed;
    }
    final oldDiff = valueText(oldWidget.file, 'diff');
    final newDiff = valueText(widget.file, 'diff');
    final identityChanged =
        oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.iid != widget.iid ||
        !identical(oldWidget.api, widget.api) ||
        valueText(oldWidget.version, 'head_commit_sha') !=
            valueText(widget.version, 'head_commit_sha') ||
        diffFilePath(oldWidget.file) != diffFilePath(widget.file) ||
        oldDiff != newDiff ||
        !identical(oldWidget.diffParser, widget.diffParser);
    if (identityChanged) {
      _epoch++;
      _lines = null;
      _unavailable = null;
      _diffError = null;
      _initDiff();
    }
  }

  void _applyFeed(_DiscussionFeed feed) {
    _discussions = List<Json>.of(feed.items);
    _truncated = feed.truncated;
    _discussionsError = feed.error;
    _discussionsLoading = feed.loading;
  }

  void _onFeed() {
    if (_ignoreParentFeed || !mounted || _disposed) return;
    setState(() => _applyFeed(widget.feed.value));
    if (widget.initialTarget != null) {
      _seekLow = 0;
      _seekHigh = -1;
      _seekStall = 0;
      _scheduleReveal();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    widget.feed.removeListener(_onFeed);
    _scroll.dispose();
    super.dispose();
  }

  void _trackBuilt(int index, bool built) {
    if (built) {
      _builtLines.add(index);
    } else {
      _builtLines.remove(index);
    }
  }

  Widget _builtRow(int index, Widget child) => _BuiltLine(
    key: ValueKey('built-line-$index'),
    index: index,
    onBuilt: _trackBuilt,
    child: child,
  );

  Map<int, List<Json>> _anchored(List<DiffLine> lines) {
    final grouped = <int, List<Json>>{};
    for (final discussion in _discussions) {
      final position = _textPosition(discussion);
      if (position == null || !_shasMatch(position, widget.version)) continue;
      int? index;
      for (var i = 0; i < lines.length; i++) {
        if (_mapsToLine(position, widget.file, lines[i])) {
          index = i;
          break;
        }
      }
      if (index == null) continue;
      grouped.putIfAbsent(index, () => <Json>[]).add(discussion);
    }
    return grouped;
  }

  List<Json> _others(Set<Json> anchored) {
    final result = <Json>[];
    for (final discussion in _discussions) {
      if (anchored.contains(discussion)) continue;
      final position = _textPosition(discussion);
      if (position == null || !_positionClaimsFile(position, widget.file)) {
        continue;
      }
      result.add(discussion);
    }
    return result;
  }

  bool _targetOnLine(List<DiffLine> lines) {
    final target = widget.initialTarget;
    if (target == null || !_targetShasMatch()) return false;
    return _targetLineIndex(lines) != null;
  }

  String get _fallbackReason {
    final target = widget.initialTarget;
    if (target == null) return l10n.discussionOnOlderDiff;
    return _unplacedReason({
      'base_sha': target.baseSha,
      'start_sha': target.startSha,
      'head_sha': target.headSha,
    }, widget.version);
  }

  bool _targetShasMatch() {
    final target = widget.initialTarget;
    if (target == null) return false;
    if (target.baseSha.isEmpty ||
        target.startSha.isEmpty ||
        target.headSha.isEmpty) {
      return false;
    }
    return target.baseSha == widget.version['base_commit_sha'] &&
        target.startSha == widget.version['start_commit_sha'] &&
        target.headSha == widget.version['head_commit_sha'];
  }

  int? _targetLineIndex(List<DiffLine> lines) {
    final target = widget.initialTarget;
    if (target == null || !_targetShasMatch()) return null;
    final position = _targetPosition(target);
    for (var i = 0; i < lines.length; i++) {
      if (_mapsToLine(position, widget.file, lines[i])) return i;
    }
    return null;
  }

  bool _showOther(List<DiffLine> lines) {
    final anchored = _anchored(lines);
    final anchoredSet = <Json>{for (final group in anchored.values) ...group};
    return _others(anchoredSet).isNotEmpty ||
        (widget.initialTarget != null && _targetLineIndex(lines) == null);
  }

  bool _walkCurrent(int epoch) => mounted && !_disposed && epoch == _epoch;

  void _scheduleReveal() {
    if (_revealScheduled || _disposed) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted && !_disposed) _revealTarget();
    });
  }

  void _revealTarget() {
    if (!mounted || _disposed || widget.initialTarget == null) return;
    if (_diffLoading ||
        (_lines == null && _unavailable == null && _diffError == null)) {
      return;
    }
    final target = _targetKey.currentContext;
    if (target != null) {
      unawaited(Scrollable.ensureVisible(target, alignment: 0.05));
      return;
    }
    if (!_scroll.hasClients) {
      _scheduleReveal();
      return;
    }
    final position = _scroll.position;
    if (!position.hasContentDimensions) {
      _scheduleReveal();
      return;
    }
    final lines = _lines;
    final index = lines == null ? 0 : (_targetLineIndex(lines) ?? lines.length);
    final span = position.maxScrollExtent;
    if (span <= 0) {
      _seekStall++;
      if (_seekStall > 8) return;
      _scheduleReveal();
      return;
    }
    if (_seekHigh < 0 || _seekHigh > span) _seekHigh = span;
    if (_seekLow > _seekHigh) {
      _seekLow = 0;
      _seekHigh = span;
    }
    final built = _builtRange();
    var next = position.pixels;
    if (built == null) {
      final itemCount = lines == null
          ? 1
          : lines.length + (_showOther(lines) ? 1 : 0);
      final safeCount = itemCount < 1 ? 1 : itemCount;
      final average = (span + position.viewportDimension) / safeCount;
      next = (index * average).clamp(0.0, span);
    } else if (index < built.$1) {
      _seekHigh = math.min(_seekHigh, position.pixels);
      next = (_seekLow + _seekHigh) / 2;
    } else if (index > built.$2) {
      _seekLow = math.max(_seekLow, position.pixels);
      _seekHigh = math.max(_seekHigh, span);
      next = (_seekLow + _seekHigh) / 2;
    } else {
      _seekStall++;
      if (_seekStall > 4) return;
      _scheduleReveal();
      return;
    }
    next = next.clamp(0.0, span);
    if ((next - position.pixels).abs() < 1) {
      if (built != null && index > built.$2 && position.pixels < span - 1) {
        next = math.min(span, position.pixels + position.viewportDimension);
      } else if (built != null && index < built.$1 && position.pixels > 1) {
        next = math.max(0.0, position.pixels - position.viewportDimension);
      }
    }
    if ((next - position.pixels).abs() < 1) {
      _seekStall++;
      if (_seekStall > 4) return;
      _scheduleReveal();
      return;
    }
    _seekStall = 0;
    _scroll.jumpTo(next);
    _scheduleReveal();
  }

  (int, int)? _builtRange() {
    if (_builtLines.isEmpty) return null;
    var minBuilt = _builtLines.first;
    var maxBuilt = _builtLines.first;
    for (final built in _builtLines) {
      if (built < minBuilt) minBuilt = built;
      if (built > maxBuilt) maxBuilt = built;
    }
    return (minBuilt, maxBuilt);
  }

  Future<void> _reloadDiscussions() async {
    final epoch = ++_epoch;
    _ignoreParentFeed = true;
    setState(() {
      _reloading = true;
      _discussionsError = null;
      _discussionsLoading = false;
    });
    final loaded = await _loadDiscussions(
      widget.api,
      _mrPath,
      epoch: epoch,
      current: _walkCurrent,
    );
    if (!mounted || _disposed || epoch != _epoch) return;
    setState(() {
      if (loaded.items.isNotEmpty || loaded.error == null) {
        _discussions = loaded.items;
        _truncated = loaded.truncated;
      }
      _discussionsError = loaded.error;
      _reloading = false;
    });
  }

  Future<void> _comment(DiffLine line) async {
    if (!line.commentable) {
      return;
    }
    final oldPath = requiredString(widget.file, 'old_path');
    final newPath = requiredString(widget.file, 'new_path');
    final sha = requiredString(widget.version, 'head_commit_sha');
    final position = <String, dynamic>{
      'position_type': 'text',
      'base_sha': requiredString(widget.version, 'base_commit_sha'),
      'start_sha': requiredString(widget.version, 'start_commit_sha'),
      'head_sha': sha,
      'old_path': oldPath,
      'new_path': newPath,
      if (line.oldLine != null) 'old_line': line.oldLine,
      if (line.newLine != null) 'new_line': line.newLine,
    };
    var savedAsDraft = false;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: l10n.commentOnThisLine,
      resource:
          '${widget.project.id}/mr/${widget.iid}/$sha/$oldPath/$newPath/${line.oldLine}/${line.newLine}',
      subtitle: '$newPath · ${line.newLine ?? line.oldLine} · ${shortSha(sha)}',
      fields: [
        EditField('body', l10n.addComment, lines: 8, required: true, markdown: true),
        EditField.toggle('draft', l10n.saveToReviewDraft, hint: l10n.reviewDraftVisibilityHint),
      ],
      api: widget.api,
      projectId: widget.project.id,
      projectPath: widget.project.path,
      save: (values) async {
        final current = await widget.api.record(_mrPath);
        if (current['sha'] != sha) {
          throw ApiFailure(
            FailureKind.conflict,
            title: l10n.mergeRequestNewVersion,
            detail: l10n.reloadChangesBeforeComment,
          );
        }
        savedAsDraft = values['draft'] == 'true';
        if (savedAsDraft) {
          await widget.api.writeRecord(
            'POST',
            [..._mrPath, 'draft_notes'],
            {'note': values['body']!.trim(), 'position': position},
          );
          return;
        }
        await widget.api.writeRecord(
          'POST',
          [..._mrPath, 'discussions'],
          {'body': values['body'], 'position': position},
        );
      },
    );
    if (!saved || !mounted) return;
    if (savedAsDraft) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.draftSavedPrivate)));
      return;
    }
    await _reloadDiscussions();
  }

  Future<void> _openDraftReview() async {
    final sha = requiredString(widget.version, 'head_commit_sha');
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => DraftReviewPage(
          account: widget.account,
          api: widget.api,
          project: widget.project,
          iid: widget.iid,
          headSha: sha,
        ),
      ),
    );
  }

  Future<void> _reply(Json discussion) async {
    final id = discussion['id'];
    if (id is! String || id.isEmpty || _busy) return;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: l10n.replyToThread,
      resource: '${widget.project.id}/mr/${widget.iid}/discussion/$id/reply',
      subtitle: valueText(widget.file, 'new_path'),
      fields: [EditField('body', l10n.commentBody, required: true, lines: 8)],
      save: (values) async {
        await widget.api.writeRecord(
          'POST',
          [..._mrPath, 'discussions', id, 'notes'],
          {'body': values['body']},
        );
      },
    );
    if (saved && mounted) await _reloadDiscussions();
  }

  Future<void> _resolve(Json discussion, bool resolved) async {
    final id = discussion['id'];
    if (id is! String || id.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.writeRecord(
        'PUT',
        [..._mrPath, 'discussions', id],
        {'resolved': resolved},
      );
      if (mounted) await _reloadDiscussions();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _navSeekStall = 0;

  void _scrollToDiscussionLine(int targetIndex, int totalItemCount) {
    setState(() {
      _activeDiscussionTargetIndex = targetIndex;
      final lines = _lines;
      if (lines != null && targetIndex < lines.length) {
        final threads = _anchored(lines)[targetIndex];
        if (threads != null) {
          for (final d in threads) {
            _expanded.add('${d['id']}');
          }
        }
      } else if (targetIndex == (_lines?.length ?? 0)) {
        for (final d in _discussions) {
          _expanded.add('${d['id']}');
        }
      }
    });

    _navSeekStall = 0;
    _seekToNavTarget(targetIndex, totalItemCount);
  }

  void _seekToNavTarget(int targetIndex, int totalItemCount) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      if (targetIndex != _activeDiscussionTargetIndex) return;

      final targetContext = _navTargetKey.currentContext;
      if (targetContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            targetContext,
            alignment: 0.1,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          ),
        );
        return;
      }

      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      if (!position.hasContentDimensions) return;
      final span = position.maxScrollExtent;
      if (span <= 0) return;

      final safeCount = totalItemCount < 1 ? 1 : totalItemCount;
      final average = (span + position.viewportDimension) / safeCount;
      final built = _builtRange();

      var next = position.pixels;
      if (built == null) {
        next = (targetIndex * average).clamp(0.0, span);
      } else if (targetIndex < built.$1) {
        next = math.max(0.0, position.pixels - position.viewportDimension);
      } else if (targetIndex > built.$2) {
        next = math.min(span, position.pixels + position.viewportDimension);
      } else {
        _navSeekStall++;
        if (_navSeekStall > 4) return;
        _seekToNavTarget(targetIndex, totalItemCount);
        return;
      }

      if ((next - position.pixels).abs() < 1) {
        _navSeekStall++;
        if (_navSeekStall > 4) return;
        _seekToNavTarget(targetIndex, totalItemCount);
        return;
      }

      _navSeekStall = 0;
      unawaited(
        _scroll
            .animateTo(
              next,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            )
            .then((_) {
              if (!mounted || _disposed) return;
              if (targetIndex == _activeDiscussionTargetIndex) {
                _seekToNavTarget(targetIndex, totalItemCount);
              }
            }),
      );
    });
  }

  Widget? _buildDiscussionNavigator(
    BuildContext context, {
    required List<int> unresolvedLineIndices,
    required int unresolvedCount,
    required int totalDiscussionsCount,
    required int totalItemCount,
  }) {
    if (totalDiscussionsCount == 0) {
      return null;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isResolvedAll = unresolvedCount == 0;
    final totalTargets = unresolvedLineIndices.length;
    final currentPos = _activeDiscussionTargetIndex == null
        ? -1
        : unresolvedLineIndices.indexOf(_activeDiscussionTargetIndex!);

    return Material(
      key: const ValueKey('diff-discussion-navigator'),
      elevation: 4,
      borderRadius: BorderRadius.circular(28),
      color: isResolvedAll
          ? colorScheme.surfaceContainer
          : colorScheme.surfaceContainerHigh,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: isResolvedAll
                ? colorScheme.outlineVariant.withValues(alpha: 0.5)
                : colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isResolvedAll
                  ? Icons.check_circle_outline
                  : Icons.mark_chat_unread_outlined,
              size: 20,
              color: isResolvedAll ? Colors.green : colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              isResolvedAll
                  ? l10n.unresolvedThreadsZero
                  : currentPos >= 0
                  ? l10n.unresolvedThreadsProgress(unresolvedCount, currentPos + 1, totalTargets)
                  : l10n.unresolvedThreadsCount(unresolvedCount),
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: isResolvedAll
                    ? colorScheme.outline
                    : colorScheme.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('diff-nav-prev'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.keyboard_arrow_up, size: 22),
              tooltip: l10n.previousThread,
              color: isResolvedAll
                  ? colorScheme.outline
                  : colorScheme.onSurface,
              onPressed: isResolvedAll || unresolvedLineIndices.isEmpty
                  ? null
                  : () {
                      final len = unresolvedLineIndices.length;
                      final prevPos = currentPos <= 0
                          ? len - 1
                          : currentPos - 1;
                      _scrollToDiscussionLine(
                        unresolvedLineIndices[prevPos],
                        totalItemCount,
                      );
                    },
            ),
            IconButton(
              key: const ValueKey('diff-nav-next'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.keyboard_arrow_down, size: 22),
              tooltip: l10n.nextThread,
              color: isResolvedAll
                  ? colorScheme.outline
                  : colorScheme.onSurface,
              onPressed: isResolvedAll || unresolvedLineIndices.isEmpty
                  ? null
                  : () {
                      final len = unresolvedLineIndices.length;
                      final nextPos = (currentPos + 1) % len;
                      _scrollToDiscussionLine(
                        unresolvedLineIndices[nextPos],
                        totalItemCount,
                      );
                    },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final scheme = Theme.of(context).colorScheme;
    final anchored = lines == null ? <int, List<Json>>{} : _anchored(lines);
    final anchoredSet = <Json>{for (final group in anchored.values) ...group};
    final others = _others(anchoredSet);
    final onLine = lines != null && _targetOnLine(lines);
    final showOther =
        others.isNotEmpty || (widget.initialTarget != null && !onLine);
    final targetIndex = lines == null ? null : _targetLineIndex(lines);

    final totalDiscussionsCount =
        anchored.values.fold<int>(0, (sum, list) => sum + list.length) +
        others.length;
    var unresolvedCount = 0;
    final unresolvedLineIndices = <int>[];
    if (lines != null) {
      final sortedKeys = anchored.keys.toList()..sort();
      for (final lineIndex in sortedKeys) {
        final list = anchored[lineIndex]!;
        final unresolvedInLine = list.where((d) => !_resolved(d)).length;
        if (unresolvedInLine > 0) {
          unresolvedCount += unresolvedInLine;
          unresolvedLineIndices.add(lineIndex);
        }
      }
      final unresolvedOthers = others.where((d) => !_resolved(d)).length;
      if (unresolvedOthers > 0) {
        unresolvedCount += unresolvedOthers;
        if (showOther) {
          unresolvedLineIndices.add(lines.length);
        }
      }
    } else {
      unresolvedCount = others.where((d) => !_resolved(d)).length;
      if (unresolvedCount > 0 && showOther) {
        unresolvedLineIndices.add(0);
      }
    }
    final totalItemCount = lines == null
        ? 1
        : lines.length + (showOther ? 1 : 0);

    return Scaffold(
      floatingActionButton: _diffLoading || _diffError != null
          ? null
          : _buildDiscussionNavigator(
              context,
              unresolvedLineIndices: unresolvedLineIndices,
              unresolvedCount: unresolvedCount,
              totalDiscussionsCount: totalDiscussionsCount,
              totalItemCount: totalItemCount,
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      appBar: AppBar(
        title: Text(
          diffFilePath(widget.file),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          ResourceShareButton(
            uri: widget.account.instance.projectWeb(
              '${widget.project.path}/-/merge_requests/${widget.iid}/diffs',
            ),
            ownerKey: (
              widget.account.key,
              widget.api,
              widget.project.id,
              widget.iid,
              widget.version['head_commit_sha'],
            ),
            isCurrent: () => mounted && !_disposed && !widget.api.isClosed,
          ),
          IconButton(
            tooltip: l10n.reviewDrafts,
            icon: const Icon(Icons.rate_review_outlined),
            onPressed: _openDraftReview,
          ),
          IconButton(
            key: const ValueKey('diff-file-viewed-toggle'),
            tooltip: _viewed ? l10n.markAsNotViewed : l10n.markAsViewed,
            icon: Icon(
              _viewed ? Icons.check_circle : Icons.circle_outlined,
              color: _viewed ? Colors.green : null,
            ),
            onPressed: () {
              setState(() => _viewed = !_viewed);
              widget.onToggleViewed?.call();
            },
          ),
          IconButton(
            tooltip: l10n.openInGitlab,
            icon: const Icon(Icons.open_in_new),
            onPressed: () => openExternal(
              context,
              widget.account.instance.projectWeb(
                '${widget.project.path}/-/merge_requests/${widget.iid}/diffs',
              ),
            ),
          ),
        ],
      ),
      body: gestureSafe(
        _diffLoading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(strokeWidth: 2),
                    SizedBox(height: 12),
                    Text(l10n.preparingDiff),
                  ],
                ),
              )
            : _diffError != null
            ? ListView(
                controller: _scroll,
                children: [
                  FailureNotice(
                    _diffError!,
                    onRetry: () => setState(() => _initDiff()),
                    account: widget.account,
                    resourceLabel: diffFilePath(widget.file),
                    onSwitchAccount: endSessionFrom(context),
                  ),
                ],
              )
            : lines == null
            ? ListView(
                controller: _scroll,
                children: [
                  EmptyState(
                    l10n.cannotDisplayDiff,
                    detail: _unavailable,
                    icon: Icons.code_off,
                  ),
                  if (_discussionsLoading)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(l10n.loadingDiscussions),
                    ),
                  if (_truncated)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(_discussionPageBoundNote),
                    ),
                  if (_discussionsError != null)
                    FailureNotice(
                      _discussionsError!,
                      onRetry: _reloadDiscussions,
                      account: widget.account,
                      resourceLabel:
                          l10n.mergeRequestThreadsTitle(widget.project.path, widget.iid),
                      onSwitchAccount: endSessionFrom(context),
                    ),
                  if (showOther)
                    KeyedSubtree(
                      key: widget.initialTarget != null ? _targetKey : null,
                      child: _OtherVersionSection(
                        discussions: others,
                        version: widget.version,
                        fallbackReason: _fallbackReason,
                      ),
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      l10n.tapLineToComment(shortSha(valueText(widget.version, 'head_commit_sha'))),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (_discussionsLoading)
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(l10n.loadingDiscussions),
                    ),
                  if (_truncated)
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_discussionPageBoundNote),
                    ),
                  if (_reloading) const LinearProgressIndicator(minHeight: 2),
                  if (_discussionsError != null)
                    FailureNotice(
                      _discussionsError!,
                      onRetry: _reloadDiscussions,
                      account: widget.account,
                      resourceLabel:
                          l10n.mergeRequestThreadsTitle(widget.project.path, widget.iid),
                      onSwitchAccount: endSessionFrom(context),
                    ),
                  Expanded(
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.only(bottom: 72),
                        itemCount: lines.length + (showOther ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == lines.length) {
                            final isNavTarget =
                                _activeDiscussionTargetIndex == index;
                            final isInitialTarget =
                                !onLine && widget.initialTarget != null;
                            final section = _OtherVersionSection(
                              discussions: others,
                              version: widget.version,
                              fallbackReason: _fallbackReason,
                            );
                            Widget content = section;
                            if (isNavTarget) {
                              content = KeyedSubtree(
                                key: _navTargetKey,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: scheme.tertiary,
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: content,
                                ),
                              );
                            }
                            if (isInitialTarget) {
                              content = KeyedSubtree(
                                key: _targetKey,
                                child: content,
                              );
                            }
                            return _builtRow(index, content);
                          }
                          final line = lines[index];
                          final marker = line.kind == 'add'
                              ? '+'
                              : line.kind == 'remove'
                              ? '−'
                              : ' ';
                          final background = line.kind == 'add'
                              ? WorkshopColors.of(
                                  context,
                                ).diffAdded.withValues(alpha: .16)
                              : line.kind == 'remove'
                              ? WorkshopColors.of(
                                  context,
                                ).diffRemoved.withValues(alpha: .16)
                              : line.kind == 'hunk'
                              ? scheme.surfaceContainerHighest
                              : null;
                          final threads = anchored[index] ?? const <Json>[];
                          final row = Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Material(
                                color: background ?? scheme.surface,
                                child: InkWell(
                                  key: ValueKey('diff-line-$index'),
                                  onTap: line.commentable
                                      ? () => _comment(line)
                                      : null,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: 48,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 14,
                                      ),
                                      child: Directionality(textDirection: TextDirection.ltr, child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          SizedBox(
                                            width: 30,
                                            child: Text(
                                              '${line.oldLine ?? ''}',
                                              textAlign: TextAlign.right,
                                              textScaler:
                                                  MediaQuery.textScalerOf(
                                                    context,
                                                  ).clamp(maxScaleFactor: 1.3),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 30,
                                            child: Text(
                                              '${line.newLine ?? ''}',
                                              textAlign: TextAlign.right,
                                              textScaler:
                                                  MediaQuery.textScalerOf(
                                                    context,
                                                  ).clamp(maxScaleFactor: 1.3),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 20,
                                            child: Text(
                                              marker,
                                              textAlign: TextAlign.center,
                                              textScaler:
                                                  MediaQuery.textScalerOf(
                                                    context,
                                                  ).clamp(maxScaleFactor: 1.3),
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              line.text,
                                              style: const TextStyle(
                                                fontFamily: codeFontFamily,
                                                fontFamilyFallback: [
                                                  'Menlo',
                                                  'monospace',
                                                ],
                                                fontSize: 13,
                                                height: 1.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      )),
                                    ),
                                  ),
                                ),
                              ),
                              for (final discussion in threads)
                                _DiffThreadCard(
                                  key: ValueKey(
                                    'diff-thread-${discussion['id']}',
                                  ),
                                  discussion: discussion,
                                  expanded: _expanded.contains(
                                    '${discussion['id']}',
                                  ),
                                  busy: _busy,
                                  base: widget.account.instance.projectWeb(
                                    widget.project.path,
                                  ),
                                  api: widget.api,
                                  projectId: widget.project.id,
                                  projectPath: widget.project.path,
                                  budget: _attachments,
                                  onExpand: () => setState(
                                    () => _expanded.add('${discussion['id']}'),
                                  ),
                                  onReply: () => _reply(discussion),
                                  onResolve: _resolvable(discussion)
                                      ? () => _resolve(
                                          discussion,
                                          !_resolved(discussion),
                                        )
                                      : null,
                                  onApplied: () async {
                                    await _reloadDiscussions();
                                    widget.onApplied?.call();
                                  },
                                ),
                            ],
                          );
                          final isNavTarget =
                              index == _activeDiscussionTargetIndex;
                          final isInitialTarget =
                              onLine && index == targetIndex;
                          Widget content = row;
                          if (isNavTarget) {
                            content = KeyedSubtree(
                              key: _navTargetKey,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: scheme.tertiary,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: content,
                              ),
                            );
                          }
                          if (isInitialTarget) {
                            content = KeyedSubtree(
                              key: _targetKey,
                              child: content,
                            );
                          }
                          return _builtRow(index, content);
                        },
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

bool _resolvable(Json discussion) =>
    valueObjects(discussion, 'notes').any((note) => note['resolvable'] == true);

bool _resolved(Json discussion) {
  final notes = valueObjects(
    discussion,
    'notes',
  ).where((note) => note['resolvable'] == true);
  if (notes.isEmpty) return discussion['resolved'] == true;
  return notes.every((note) => note['resolved'] == true);
}

class _BuiltLine extends StatefulWidget {
  const _BuiltLine({
    super.key,
    required this.index,
    required this.onBuilt,
    required this.child,
  });
  final int index;
  final void Function(int index, bool built) onBuilt;
  final Widget child;
  @override
  State<_BuiltLine> createState() => _BuiltLineState();
}

class _BuiltLineState extends State<_BuiltLine> {
  @override
  void initState() {
    super.initState();
    widget.onBuilt(widget.index, true);
  }

  @override
  void didUpdateWidget(_BuiltLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    oldWidget.onBuilt(oldWidget.index, false);
    widget.onBuilt(widget.index, true);
  }

  @override
  void dispose() {
    widget.onBuilt(widget.index, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DiffThreadCard extends StatelessWidget {
  const _DiffThreadCard({
    super.key,
    required this.discussion,
    required this.expanded,
    required this.busy,
    required this.base,
    required this.api,
    required this.projectId,
    required this.projectPath,
    required this.budget,
    required this.onExpand,
    required this.onReply,
    required this.onResolve,
    this.onApplied,
  });
  final Json discussion;
  final bool expanded;
  final bool busy;
  final Uri base;
  final GitLabApi api;
  final int projectId;
  final String projectPath;
  final AttachmentBudget budget;
  final VoidCallback onExpand;
  final VoidCallback onReply;
  final VoidCallback? onResolve;
  final VoidCallback? onApplied;

  @override
  Widget build(BuildContext context) {
    final notes = valueObjects(discussion, 'notes');
    if (notes.isEmpty) return const SizedBox.shrink();
    final visible = expanded || notes.length <= 2
        ? notes
        : notes.take(2).toList();
    final theme = Theme.of(context);
    final resolved = _resolved(discussion);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < visible.length; index++) ...[
                if (index > 0) const Divider(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        isolated('@${valueText(valueObject(visible[index], 'author'), 'username')}'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (index == 0 && resolved)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle_outline,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(l10n.resolvedLabel, style: theme.textTheme.labelMedium),
                          ],
                        ),
                      ),
                  ],
                ),
                Text(
                  relativeDate(valueText(visible[index], 'created_at')),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                MarkdownView(
                  valueText(visible[index], 'body'),
                  base: base,
                  api: api,
                  projectId: projectId,
                  projectWeb: base,
                  projectPath: projectPath,
                  budget: budget,
                ),
                for (final suggestion in parseNoteSuggestions(
                  visible[index],
                )) ...[
                  const SizedBox(height: 6),
                  SuggestedChangeCard(
                    suggestion: suggestion,
                    api: api,
                    onApplied: onApplied,
                  ),
                ],
              ],
              if (notes.length - visible.length > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    l10n.moreNotesCount(notes.length - visible.length),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (!expanded && notes.length > 2)
                TextButton(
                  onPressed: onExpand,
                  child: Text(l10n.showAllNotes(notes.length)),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: busy ? null : onReply,
                    child: Text(l10n.replyAction),
                  ),
                  if (onResolve != null)
                    TextButton(
                      onPressed: busy ? null : onResolve,
                      child: Text(resolved ? l10n.reopenThread : l10n.resolveThread),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OtherVersionSection extends StatelessWidget {
  const _OtherVersionSection({
    super.key,
    required this.discussions,
    required this.version,
    this.fallbackPath = '',
    this.fallbackNewLine,
    this.fallbackOldLine,
    String? fallbackReason,
  }) : _fallbackReasonArg = fallbackReason;
  final List<Json> discussions;
  final Json version;
  final String fallbackPath;
  final int? fallbackNewLine;
  final int? fallbackOldLine;
  final String? _fallbackReasonArg;
  String get fallbackReason => _fallbackReasonArg ?? l10n.discussionOnOlderDiff;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = discussions.isEmpty
        ? [
            _OtherVersionCard(
              path: fallbackPath,
              lines: [
                if (fallbackNewLine != null) l10n.fallbackNewDiffLine(fallbackNewLine),
                if (fallbackOldLine != null) l10n.fallbackOldDiffLine(fallbackOldLine),
              ].join(' · '),
              excerpt: '',
              reason: fallbackReason,
            ),
          ]
        : [for (final discussion in discussions) _cardFor(discussion)];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.threadsOnOtherVersions,
            key: const ValueKey('diff-other-section'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...cards,
        ],
      ),
    );
  }

  Widget _cardFor(Json discussion) {
    final notes = valueObjects(discussion, 'notes');
    final position = _textPosition(discussion) ?? const <String, dynamic>{};
    return _OtherVersionCard(
      key: ValueKey('diff-other-${discussion['id']}'),
      path: _positionPath(position),
      lines: _positionLines(position),
      excerpt: notes.isEmpty ? '' : _excerpt(valueText(notes.first, 'body')),
      reason: _unplacedReason(position, version),
    );
  }
}

class _OtherVersionCard extends StatelessWidget {
  const _OtherVersionCard({
    super.key,
    required this.path,
    required this.lines,
    required this.excerpt,
    required this.reason,
  });
  final String path;
  final String lines;
  final String excerpt;
  final String reason;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (path.isNotEmpty)
              Text(
                path,
                style: const TextStyle(
                  fontFamily: codeFontFamily,
                  fontFamilyFallback: ['Menlo', 'monospace'],
                ),
              ),
            if (lines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(lines, style: theme.textTheme.bodySmall),
              ),
            if (excerpt.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(excerpt),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(reason),
            ),
          ],
        ),
      ),
    );
  }
}
