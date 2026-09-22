import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/failure.dart';
import '../../core/unified_diff.dart';
import '../../shared/attachment_budget.dart';
import '../../shared/external_link.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'editor.dart';
import '../../shared/theme.dart';

const _maxDiscussionPages = 20;
const _discussionPageBoundNote = '討論已達 20 頁上限，後續討論未載入。';

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

String _unplacedReason(Json position, Json version) => _shasMatch(position, version)
    ? '目前差異未提供此行（可能已折疊或超出大小上限）'
    : '以較舊版本為準，無法對應目前差異';

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

String _positionLines(Json position) {
  final parts = <String>[];
  final newLine = position['new_line'];
  final oldLine = position['old_line'];
  if (newLine is int) parts.add('新行 $newLine');
  if (oldLine is int) parts.add('舊行 $oldLine');
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
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final String expectedSha;
  final DiffTarget? initialTarget;
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

  String _targetReason(DiffTarget target) {
    final version = _version;
    if (version == null) return '以較舊版本為準，無法對應目前差異';
    return _unplacedReason({
      'base_sha': target.baseSha,
      'start_sha': target.startSha,
      'head_sha': target.headSha,
    }, version);
  }

  Future<void> _open(Json file, {DiffTarget? target}) async {
    final version = _version;
    if (version == null) return;
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
            resourceLabel: '${widget.project.path} · !${widget.iid} 差異',
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }
    final files = valueObjects(_version ?? {}, 'diffs');
    final target = widget.initialTarget;
    final missingTarget = target != null && _fileFor(target) == null;
    final unmatched = _unmatchedDiscussions();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '固定版本 ${shortSha(widget.expectedSha)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_version?['overflow'] == true)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('GitLab 限制了部分差異。下列檔案不代表完整變更。'),
            ),
          if (_discussionsLoading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('正在載入討論'),
            ),
          if (_discussionsTruncated)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(_discussionPageBoundNote),
            ),
          if (_discussionsError != null)
            FailureNotice(
              _discussionsError!,
              onRetry: _load,
              account: widget.account,
              resourceLabel: '${widget.project.path} · !${widget.iid} 討論',
              onSwitchAccount: endSessionFrom(context),
            ),
          if (files.isEmpty)
            const EmptyState('沒有可顯示的文字差異', detail: '可能沒有變更，或差異未由伺服器提供。'),
          for (final file in files)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Card(
                child: ListTile(
                  leading: Icon(
                    file['new_file'] == true
                        ? Icons.add_box_outlined
                        : file['deleted_file'] == true
                        ? Icons.indeterminate_check_box_outlined
                        : Icons.code,
                  ),
                  title: Text(
                    valueText(file, 'new_path', valueText(file, 'old_path')),
                  ),
                  subtitle: file['renamed_file'] == true
                      ? Text('原路徑：${valueText(file, 'old_path')}')
                      : null,
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => _open(file),
                ),
              ),
            ),
          if (unmatched.isNotEmpty || missingTarget)
            _OtherVersionSection(
              key: _orphanKey,
              version: _version ?? const <String, dynamic>{},
              discussions: unmatched,
              fallbackPath: missingTarget ? target.path : '',
              fallbackNewLine: missingTarget ? target.newLine : null,
              fallbackOldLine: missingTarget ? target.oldLine : null,
              fallbackReason: missingTarget
                  ? _targetReason(target)
                  : '以較舊版本為準，無法對應目前差異',
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
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int iid;
  final Json file;
  final Json version;
  final ValueNotifier<_DiscussionFeed> feed;
  final DiffTarget? initialTarget;
  @override
  State<_DiffFileScreen> createState() => _DiffFileScreenState();
}

class _DiffFileScreenState extends State<_DiffFileScreen> {
  List<DiffLine>? _lines;
  String? _unavailable;
  late List<Json> _discussions;
  late bool _truncated;
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
  List<String> get _mrPath => [
    'projects',
    '${widget.project.id}',
    'merge_requests',
    '${widget.iid}',
  ];

  @override
  void initState() {
    super.initState();
    _applyFeed(widget.feed.value);
    widget.feed.addListener(_onFeed);
    final diff = valueText(widget.file, 'diff');
    if (widget.file['too_large'] == true ||
        widget.file['collapsed'] == true ||
        diff.isEmpty) {
      _unavailable = 'GitLab 未提供這份文字差異，或內容為二進位檔案。';
    } else {
      try {
        _lines = parseUnifiedDiff(diff);
      } on FormatException {
        _unavailable = '這份差異不完整或超過排版上限，已停用行內留言，避免貼錯位置。';
      }
    }
    if (widget.initialTarget != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealTarget());
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
    if (target == null) return '以較舊版本為準，無法對應目前差異';
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
    final anchoredSet = <Json>{
      for (final group in anchored.values) ...group,
    };
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
    await openEditor(
      context,
      account: widget.account,
      title: '對這一行留言',
      resource:
          '${widget.project.id}/mr/${widget.iid}/$sha/$oldPath/$newPath/${line.oldLine}/${line.newLine}',
      subtitle: '$newPath · ${line.newLine ?? line.oldLine} · ${shortSha(sha)}',
      fields: const [EditField('body', '留言', lines: 8, required: true, markdown: true)],
      api: widget.api,
      projectId: widget.project.id,
      projectPath: widget.project.path,
      save: (values) async {
        final current = await widget.api.record(_mrPath);
        if (current['sha'] != sha) {
          throw const ApiFailure(FailureKind.conflict);
        }
        await widget.api.writeRecord(
          'POST',
          [..._mrPath, 'discussions'],
          {'body': values['body'], 'position': position},
        );
      },
    );
  }

  Future<void> _reply(Json discussion) async {
    final id = discussion['id'];
    if (id is! String || id.isEmpty || _busy) return;
    final saved = await openEditor(
      context,
      account: widget.account,
      title: '回覆討論',
      resource: '${widget.project.id}/mr/${widget.iid}/discussion/$id/reply',
      subtitle: valueText(widget.file, 'new_path'),
      fields: const [EditField('body', '留言內容', required: true, lines: 8)],
      save: (values) async {
        await widget.api.writeRecord('POST', [
          ..._mrPath,
          'discussions',
          id,
          'notes',
        ], {'body': values['body']});
      },
    );
    if (saved && mounted) await _reloadDiscussions();
  }

  Future<void> _resolve(Json discussion, bool resolved) async {
    final id = discussion['id'];
    if (id is! String || id.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.writeRecord('PUT', [
        ..._mrPath,
        'discussions',
        id,
      ], {'resolved': resolved});
      if (mounted) await _reloadDiscussions();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final scheme = Theme.of(context).colorScheme;
    final anchored = lines == null
        ? <int, List<Json>>{}
        : _anchored(lines);
    final anchoredSet = <Json>{
      for (final group in anchored.values) ...group,
    };
    final others = _others(anchoredSet);
    final onLine = lines != null && _targetOnLine(lines);
    final showOther =
        others.isNotEmpty || (widget.initialTarget != null && !onLine);
    final targetIndex = lines == null ? null : _targetLineIndex(lines);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          valueText(widget.file, 'new_path'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '在 GitLab 開啟',
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
      body: gestureSafe(lines == null
          ? ListView(
              controller: _scroll,
              children: [
                EmptyState(
                  '無法顯示差異',
                  detail: _unavailable,
                  icon: Icons.code_off,
                ),
                if (_discussionsLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('正在載入討論'),
                  ),
                if (_truncated)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(_discussionPageBoundNote),
                  ),
                if (_discussionsError != null)
                  FailureNotice(
                    _discussionsError!,
                    onRetry: _reloadDiscussions,
                    account: widget.account,
                    resourceLabel:
                        '${widget.project.path} · !${widget.iid} 討論',
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
                    '點選程式碼行新增留言 · ${shortSha(valueText(widget.version, 'head_commit_sha'))}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_discussionsLoading)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('正在載入討論'),
                  ),
                if (_truncated)
                  const Padding(
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
                        '${widget.project.path} · !${widget.iid} 討論',
                    onSwitchAccount: endSessionFrom(context),
                  ),
                Expanded(
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: lines.length + (showOther ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == lines.length) {
                          return _builtRow(
                            index,
                            KeyedSubtree(
                              key: !onLine && widget.initialTarget != null
                                  ? _targetKey
                                  : null,
                              child: _OtherVersionSection(
                                discussions: others,
                                version: widget.version,
                                fallbackReason: _fallbackReason,
                              ),
                            ),
                          );
                        }
                        final line = lines[index];
                        final marker = line.kind == 'add'
                            ? '+'
                            : line.kind == 'remove'
                            ? '−'
                            : ' ';
                        final background = line.kind == 'add'
                            ? WorkshopColors.of(context).diffAdded.withValues(alpha: .16)
                            : line.kind == 'remove'
                            ? WorkshopColors.of(context).diffRemoved.withValues(alpha: .16)
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
                                    child: Row(
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
                                              fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'],
                                              fontSize: 13,
                                              height: 1.5,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
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
                              ),
                          ],
                        );
                        if (onLine && index == targetIndex) {
                          return _builtRow(
                            index,
                            KeyedSubtree(key: _targetKey, child: row),
                          );
                        }
                        return _builtRow(index, row);
                      },
                    ),
                  ),
                ),
              ],
            )),
    );
  }
}

bool _resolvable(Json discussion) => valueObjects(
  discussion,
  'notes',
).any((note) => note['resolvable'] == true);

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
                        '@${valueText(valueObject(visible[index], 'author'), 'username')}',
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
                            Text('已解決', style: theme.textTheme.labelMedium),
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
              ],
              if (notes.length - visible.length > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '另 ${notes.length - visible.length} 則',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (!expanded && notes.length > 2)
                TextButton(
                  onPressed: onExpand,
                  child: Text('顯示全部 ${notes.length} 則'),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: busy ? null : onReply,
                    child: const Text('回覆'),
                  ),
                  if (onResolve != null)
                    TextButton(
                      onPressed: busy ? null : onResolve,
                      child: Text(resolved ? '重新開啟討論' : '解決討論'),
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
    this.fallbackReason = '以較舊版本為準，無法對應目前差異',
  });
  final List<Json> discussions;
  final Json version;
  final String fallbackPath;
  final int? fallbackNewLine;
  final int? fallbackOldLine;
  final String fallbackReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = discussions.isEmpty
        ? [
            _OtherVersionCard(
              path: fallbackPath,
              lines: [
                if (fallbackNewLine != null) '新行 $fallbackNewLine',
                if (fallbackOldLine != null) '舊行 $fallbackOldLine',
              ].join(' · '),
              excerpt: '',
              reason: fallbackReason,
            ),
          ]
        : [
            for (final discussion in discussions)
              _cardFor(discussion),
          ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '其他版本的討論',
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
              Text(path, style: const TextStyle(fontFamily: codeFontFamily, fontFamilyFallback: ['Menlo', 'monospace'])),
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
