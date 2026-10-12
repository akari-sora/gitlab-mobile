import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/repository_graph.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'commit_page.dart';
import 'picker_sheet.dart';
import 'record_controller.dart';

class RepositoryGraphPage extends StatefulWidget {
  const RepositoryGraphPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.initialRef,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final String? initialRef;

  @override
  State<RepositoryGraphPage> createState() => _RepositoryGraphPageState();
}

class _RepositoryGraphPageState extends State<RepositoryGraphPage> {
  static const int _pageSize = 30;
  static const int _maxCommits = 300;
  late final TextEditingController _ref;
  late RecordController _records;
  late String _activeRef;

  String get _defaultRef {
    final requested = widget.initialRef?.trim() ?? '';
    if (requested.isNotEmpty) return requested;
    final branch = widget.project.defaultBranch?.trim() ?? '';
    return branch.isEmpty ? 'HEAD' : branch;
  }

  @override
  void initState() {
    super.initState();
    _activeRef = _defaultRef;
    _ref = TextEditingController(text: _activeRef);
    _records = _newController();
    unawaited(_records.refresh());
  }

  @override
  void didUpdateWidget(covariant RepositoryGraphPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.api, widget.api) &&
        oldWidget.account.key == widget.account.key &&
        oldWidget.project.id == widget.project.id &&
        oldWidget.initialRef == widget.initialRef) {
      return;
    }
    _records.dispose();
    _activeRef = _defaultRef;
    _ref.text = _activeRef;
    _records = _newController();
    unawaited(_records.refresh());
  }

  RecordController _newController() {
    final api = widget.api;
    final projectId = widget.project.id;
    final ref = _activeRef;
    return RecordController((next) async {
      final page = await api.records(
        ['projects', '$projectId', 'repository', 'commits'],
        query: {'ref_name': ref, 'order': 'topo', 'per_page': '$_pageSize'},
        next: next,
      );
      try {
        for (final value in page.items) {
          RepositoryGraphCommit.fromJson(value);
        }
      } on FormatException {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      return page;
    });
  }

  @override
  void dispose() {
    _records.dispose();
    _ref.dispose();
    super.dispose();
  }

  void _applyRef(String value) {
    final next = value.trim();
    if (next.isEmpty || next == _activeRef) return;
    _activeRef = next;
    _ref.text = next;
    final old = _records;
    setState(() => _records = _newController());
    old.dispose();
    unawaited(_records.refresh());
  }

  Future<void> _pickBranch() async {
    final api = widget.api;
    final accountKey = widget.account.key;
    final projectId = widget.project.id;
    final selected = await showChoicePicker(
      context,
      api: api,
      account: widget.account,
      projectId: projectId,
      source: PickerSource.branches,
      multi: false,
      title: '選擇分支',
      initial: [PickerChoice(id: _activeRef, name: _activeRef)],
    );
    if (!mounted ||
        !identical(api, widget.api) ||
        accountKey != widget.account.key ||
        projectId != widget.project.id ||
        selected == null ||
        selected.isEmpty) {
      return;
    }
    _applyRef(selected.single.name);
  }

  Future<void> _pickTag() async {
    final api = widget.api;
    final accountKey = widget.account.key;
    final projectId = widget.project.id;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: .86,
        child: _TagPickerSheet(
          account: widget.account,
          api: api,
          projectId: projectId,
        ),
      ),
    );
    if (!mounted ||
        !identical(api, widget.api) ||
        accountKey != widget.account.key ||
        projectId != widget.project.id ||
        selected == null) {
      return;
    }
    _applyRef(selected);
  }

  void _openCommit(RepositoryGraphCommit commit) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CommitDetailPage(
          account: widget.account,
          api: widget.api,
          project: widget.project,
          sha: commit.id,
          initialCommit: commit.raw,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('提交圖譜'),
      actions: [
        IconButton(
          tooltip: '重新整理',
          onPressed: () => unawaited(_records.refresh()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: gestureSafe(
      Column(
        children: [
          _controls(),
          Expanded(
            child: ListenableBuilder(
              listenable: _records,
              builder: (context, _) => _content(context),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _controls() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('graph-ref'),
          controller: _ref,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.go,
          onSubmitted: _applyRef,
          decoration: InputDecoration(
            labelText: '分支、標籤或 SHA',
            prefixIcon: const Icon(Icons.commit),
            suffixIcon: IconButton(
              key: const Key('graph-load-ref'),
              tooltip: '載入版本',
              onPressed: () => _applyRef(_ref.text),
              icon: const Icon(Icons.arrow_forward),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('graph-pick-branch'),
              onPressed: _pickBranch,
              icon: const Icon(Icons.alt_route, size: 18),
              label: const Text('選擇分支'),
            ),
            OutlinedButton.icon(
              key: const Key('graph-pick-tag'),
              onPressed: _pickTag,
              icon: const Icon(Icons.sell_outlined, size: 18),
              label: const Text('選擇標籤'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '顯示可從 $_activeRef 到達的提交歷史；不代表所有分支的完整圖譜。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  Widget _content(BuildContext context) {
    if (_records.loading && _records.items.isEmpty) return const ListSkeleton();
    if (_records.error != null && _records.items.isEmpty) {
      return ListView(
        children: [
          FailureNotice(
            _records.error!,
            account: widget.account,
            resourceLabel: '${widget.project.path} · $_activeRef · 提交圖譜',
            onRetry: _records.retry,
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }
    if (_records.items.isEmpty) {
      return const EmptyState('這個版本沒有提交紀錄', icon: Icons.account_tree_outlined);
    }
    late final RepositoryGraphLayout graph;
    try {
      graph = RepositoryGraphLayout.fromJson(_records.items);
    } on FormatException {
      return ListView(
        children: [
          FailureNotice(
            const ApiFailure(FailureKind.invalidResponse),
            account: widget.account,
            resourceLabel: '${widget.project.path} · $_activeRef · 提交圖譜',
            onRetry: _records.refresh,
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }
    return _graphList(context, graph);
  }

  Widget _graphList(BuildContext context, RepositoryGraphLayout graph) =>
      LayoutBuilder(
        builder: (context, constraints) {
          const laneWidth = 18.0;
          final graphWidth = math.max(52.0, graph.laneCount * laneWidth + 20);
          final contentWidth = math.max(constraints.maxWidth, graphWidth + 268);
          final scale = MediaQuery.textScalerOf(
            context,
          ).scale(1).clamp(1.0, 2.0);
          final rowHeight = 104.0 + (scale - 1) * 58;
          final hasBoundary = graph.boundaryParents.isNotEmpty;
          final capped = _records.items.length >= _maxCommits;
          final footerCount =
              (hasBoundary ? 1 : 0) +
              (_records.error != null ? 1 : 0) +
              (_records.next != null || capped ? 1 : 0);
          return Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                height: constraints.maxHeight,
                child: ListView.builder(
                  itemCount: graph.rows.length + footerCount,
                  itemBuilder: (context, index) {
                    if (index < graph.rows.length) {
                      return _graphRow(
                        context,
                        graph.rows[index],
                        graphWidth,
                        rowHeight,
                      );
                    }
                    var footer = index - graph.rows.length;
                    if (hasBoundary) {
                      if (footer == 0) {
                        return _boundary(
                          context,
                          graph.boundaryParents,
                          graphWidth,
                        );
                      }
                      footer--;
                    }
                    if (_records.error != null) {
                      if (footer == 0) {
                        return FailureNotice(
                          _records.error!,
                          account: widget.account,
                          onRetry: _records.retry,
                          resourceLabel: '${widget.project.path} · $_activeRef',
                          onSwitchAccount: endSessionFrom(context),
                        );
                      }
                      footer--;
                    }
                    if (capped) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('已載入 300 筆提交。請選擇更接近目標的分支、標籤或 SHA 繼續查看。'),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('graph-load-more'),
                          onPressed: _records.loadingMore
                              ? null
                              : () => unawaited(_records.more()),
                          icon: const Icon(Icons.expand_more),
                          label: Text(_records.loadingMore ? '載入中…' : '載入較早提交'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
        },
      );

  Widget _graphRow(
    BuildContext context,
    RepositoryGraphRow row,
    double graphWidth,
    double height,
  ) {
    final theme = Theme.of(context);
    final author = row.commit.authorName;
    final date = row.commit.committedDate.isEmpty
        ? ''
        : relativeDate(row.commit.committedDate);
    final meta = [
      if (author.isNotEmpty) author,
      if (date.isNotEmpty) date,
    ].join(' · ');
    return Semantics(
      button: true,
      label:
          '提交 ${row.commit.shortId}，${row.commit.title}${meta.isEmpty ? '' : '，$meta'}',
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: graphWidth,
              child: CustomPaint(
                painter: _GraphRowPainter(row, theme.colorScheme),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 5, 12, 5),
                child: Material(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    key: ValueKey('graph-commit-${row.commit.id}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _openCommit(row.commit),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            row.commit.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 5),
                          // Rows have a fixed height so the lanes line up;
                          // a second metadata line would overflow it. The
                          // variable-length author name goes last so it is
                          // the part that gets cut.
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: row.commit.shortId,
                                  style: const TextStyle(
                                    fontFamily: codeFontFamily,
                                    fontFamilyFallback: ['Menlo', 'monospace'],
                                  ),
                                ),
                                if (date.isNotEmpty) TextSpan(text: ' · $date'),
                                if (row.parents.length > 1)
                                  TextSpan(
                                    text: ' · ${row.parents.length} 個父提交',
                                  ),
                                if (author.isNotEmpty)
                                  TextSpan(text: ' · $author'),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boundary(
    BuildContext context,
    List<RepositoryGraphParent> parents,
    double graphWidth,
  ) => Container(
    key: const Key('graph-boundary'),
    padding: const EdgeInsets.fromLTRB(0, 8, 16, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: graphWidth,
          height: 24,
          child: CustomPaint(
            painter: _BoundaryPainter(parents, Theme.of(context).colorScheme),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _records.next == null ? '父提交位於目前歷史範圍外' : '尚未載入的父提交',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final parent in parents)
                    Chip(
                      label: Text(
                        shortSha(parent.sha),
                        style: const TextStyle(
                          fontFamily: codeFontFamily,
                          fontFamilyFallback: ['Menlo', 'monospace'],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _TagPickerSheet extends StatefulWidget {
  const _TagPickerSheet({
    required this.account,
    required this.api,
    required this.projectId,
  });
  final Account account;
  final GitLabApi api;
  final int projectId;
  @override
  State<_TagPickerSheet> createState() => _TagPickerSheetState();
}

class _TagPickerSheetState extends State<_TagPickerSheet> {
  late final TextEditingController _search = TextEditingController();
  late final RecordController _records = RecordController(_loader(''));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_records.refresh());
  }

  RecordLoader _loader(String search) =>
      (next) => widget.api.records(
        ['projects', '${widget.projectId}', 'repository', 'tags'],
        query: {if (search.isNotEmpty) 'search': search},
        next: next,
      );

  void _searchChanged(String value) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _records.loader = _loader(value.trim());
      unawaited(_records.refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _records.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '選擇標籤',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: '關閉',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TextField(
          controller: _search,
          onChanged: _searchChanged,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜尋標籤',
          ),
        ),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: _records,
          builder: (context, _) {
            if (_records.loading && _records.items.isEmpty) {
              return const ListSkeleton();
            }
            if (_records.error != null && _records.items.isEmpty) {
              return ListView(
                children: [
                  FailureNotice(
                    _records.error!,
                    account: widget.account,
                    onRetry: _records.retry,
                    resourceLabel: '專案標籤',
                  ),
                ],
              );
            }
            if (_records.items.isEmpty) {
              return const EmptyState('沒有符合的標籤', icon: Icons.sell_outlined);
            }
            return ListView.builder(
              itemCount:
                  _records.items.length +
                  (_records.next == null && _records.error == null ? 0 : 1),
              itemBuilder: (context, index) {
                if (index < _records.items.length) {
                  final name = valueText(_records.items[index], 'name');
                  return ListTile(
                    minTileHeight: 48,
                    leading: const Icon(Icons.sell_outlined),
                    title: Text(name),
                    subtitle: Text(
                      shortSha(valueText(_records.items[index], 'target')),
                    ),
                    onTap: name.isEmpty
                        ? null
                        : () => Navigator.pop(context, name),
                  );
                }
                if (_records.error != null) {
                  return FailureNotice(
                    _records.error!,
                    account: widget.account,
                    onRetry: _records.retry,
                    resourceLabel: '專案標籤',
                  );
                }
                return TextButton.icon(
                  onPressed: _records.loadingMore
                      ? null
                      : () => unawaited(_records.more()),
                  icon: const Icon(Icons.expand_more),
                  label: Text(_records.loadingMore ? '載入中…' : '載入更多'),
                );
              },
            );
          },
        ),
      ),
    ],
  );
}

class _GraphRowPainter extends CustomPainter {
  const _GraphRowPainter(this.row, this.scheme);
  final RepositoryGraphRow row;
  final ColorScheme scheme;

  static const double _laneWidth = 18;
  double _x(int lane) => 10 + lane * _laneWidth;
  Color _color(int lane) => [
    scheme.primary,
    scheme.tertiary,
    scheme.secondary,
    scheme.error,
  ][lane % 4];

  @override
  void paint(Canvas canvas, Size size) {
    final nodeY = math.min(32.0, size.height * .34);
    for (var lane = 0; lane < row.lanesBefore.length; lane++) {
      if (row.lanesBefore[lane] == null || lane == row.lane) continue;
      final paint = Paint()
        ..color = _color(lane)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(_x(lane), 0),
        Offset(_x(lane), size.height),
        paint,
      );
    }
    final nodePaint = Paint()
      ..color = _color(row.lane)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(_x(row.lane), 0),
      Offset(_x(row.lane), nodeY - 6),
      nodePaint,
    );
    for (final parent in row.parents) {
      final path = Path()
        ..moveTo(_x(row.lane), nodeY + 6)
        ..cubicTo(
          _x(row.lane),
          nodeY + 24,
          _x(parent.lane),
          size.height - 20,
          _x(parent.lane),
          size.height,
        );
      canvas.drawPath(
        path,
        Paint()
          ..color = _color(parent.lane)
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke,
      );
    }
    canvas.drawCircle(
      Offset(_x(row.lane), nodeY),
      6,
      Paint()
        ..color = scheme.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(_x(row.lane), nodeY),
      5,
      Paint()
        ..color = _color(row.lane)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _GraphRowPainter oldDelegate) =>
      !identical(row, oldDelegate.row) || scheme != oldDelegate.scheme;
}

class _BoundaryPainter extends CustomPainter {
  const _BoundaryPainter(this.parents, this.scheme);
  final List<RepositoryGraphParent> parents;
  final ColorScheme scheme;
  @override
  void paint(Canvas canvas, Size size) {
    final colors = [
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      scheme.error,
    ];
    for (final parent in parents) {
      final x = 10.0 + parent.lane * 18.0;
      final color = colors[parent.lane % colors.length];
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, 12),
        Paint()
          ..color = color
          ..strokeWidth = 2.2,
      );
      canvas.drawCircle(Offset(x, 16), 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _BoundaryPainter oldDelegate) =>
      !identical(parents, oldDelegate.parents) || scheme != oldDelegate.scheme;
}
