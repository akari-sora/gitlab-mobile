import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/unified_diff.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'picker_sheet.dart';

import '../../l10n/l10n.dart';
class ComparePage extends StatefulWidget {
  const ComparePage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.initialFrom,
    this.initialTo,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final String? initialFrom;
  final String? initialTo;

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  late final TextEditingController _from;
  late final TextEditingController _to;
  _CompareResult? _result;
  ApiFailure? _error;
  String? _validation;
  bool _straight = false;
  bool _loading = false;
  int _epoch = 0;
  int _generation = 0;
  _CompareSpec? _resultSpec;
  _CompareSpec? _errorSpec;
  final Set<Route<dynamic>> _pickerRoutes = <Route<dynamic>>{};

  String _initialFrom(ComparePage page) {
    final supplied = page.initialFrom?.trim() ?? '';
    return supplied.isNotEmpty ? supplied : (page.project.defaultBranch ?? '');
  }

  @override
  void initState() {
    super.initState();
    _from = TextEditingController(text: _initialFrom(widget));
    _to = TextEditingController(text: widget.initialTo?.trim() ?? '');
  }

  bool _identityChanged(ComparePage oldWidget) =>
      oldWidget.account.key != widget.account.key ||
      oldWidget.project.id != widget.project.id ||
      !identical(oldWidget.api, widget.api);

  void _dismissPickers() {
    final navigator = Navigator.of(context);
    final routes = _pickerRoutes.toList(growable: false);
    _pickerRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted) return;
      for (final route in routes) {
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ComparePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_identityChanged(oldWidget)) {
      _generation++;
      _epoch++;
      _dismissPickers();
      _from.text = _initialFrom(widget);
      _to.text = widget.initialTo?.trim() ?? '';
      _result = null;
      _resultSpec = null;
      _error = null;
      _errorSpec = null;
      _validation = null;
      _straight = false;
      _loading = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _epoch++;
    _pickerRoutes.clear();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _pickBranch(
    TextEditingController controller,
    String title,
  ) async {
    final generation = _generation;
    final api = widget.api;
    final account = widget.account;
    final projectId = widget.project.id;
    final current = controller.text.trim();
    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    final route = ModalBottomSheetRoute<List<PickerChoice>>(
      builder: (context) {
        final media = MediaQuery.of(context);
        final bottom = math.max(
          media.viewInsets.bottom,
          media.viewPadding.bottom,
        );
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final raw = constraints.maxHeight;
              final height = raw.isFinite
                  ? raw.clamp(0.0, double.infinity)
                  : 0.0;
              return SizedBox(
                height: height,
                child: ChoicePickerSheet(
                  api: api,
                  account: account,
                  projectId: projectId,
                  source: PickerSource.branches,
                  multi: false,
                  title: title,
                  initial: current.isEmpty
                      ? const []
                      : [PickerChoice(id: current, name: current)],
                ),
              );
            },
          ),
        );
      },
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      isScrollControlled: true,
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
      useSafeArea: true,
    );
    _pickerRoutes.add(route);
    List<PickerChoice>? selected;
    try {
      selected = await navigator.push(route);
    } finally {
      _pickerRoutes.remove(route);
    }
    if (!mounted ||
        generation != _generation ||
        !identical(api, widget.api) ||
        account.key != widget.account.key ||
        projectId != widget.project.id ||
        selected == null ||
        selected.isEmpty) {
      return;
    }
    controller.text = selected.single.name;
    _controlsChanged();
  }

  void _controlsChanged() {
    _epoch++;
    if (_result == null && _error == null && _validation == null && !_loading) {
      return;
    }
    setState(() {
      _result = null;
      _resultSpec = null;
      _error = null;
      _errorSpec = null;
      _validation = null;
      _loading = false;
    });
  }

  void _setStraight(bool value) {
    if (_straight == value) return;
    _epoch++;
    setState(() {
      _straight = value;
      _result = null;
      _resultSpec = null;
      _error = null;
      _errorSpec = null;
      _validation = null;
      _loading = false;
    });
  }

  Future<void> _compare() async {
    if (_loading) return;
    final spec = _CompareSpec(
      from: _from.text.trim(),
      to: _to.text.trim(),
      straight: _straight,
    );
    if (spec.from.isEmpty || spec.to.isEmpty) {
      setState(() {
        _validation = l10n.enterCompareVersions;
        _error = null;
      });
      return;
    }

    final epoch = ++_epoch;
    final api = widget.api;
    final accountKey = widget.account.key;
    final projectId = widget.project.id;
    setState(() {
      _loading = true;
      _result = null;
      _resultSpec = null;
      _error = null;
      _errorSpec = null;
      _validation = null;
    });
    try {
      final record = await api.record(
        ['projects', '$projectId', 'repository', 'compare'],
        query: {
          'from': spec.from,
          'to': spec.to,
          'straight': '${spec.straight}',
          'unidiff': 'true',
        },
      );
      if (!_current(epoch, api, accountKey, projectId)) return;
      final result = _CompareResult.fromJson(record);
      if (!_current(epoch, api, accountKey, projectId)) return;
      setState(() {
        _result = result;
        _resultSpec = spec;
        _loading = false;
      });
    } catch (error) {
      if (!_current(epoch, api, accountKey, projectId)) return;
      setState(() {
        _error = safeFailure(error);
        _errorSpec = spec;
        _loading = false;
      });
    }
  }

  bool _current(int epoch, GitLabApi api, String accountKey, int projectId) =>
      mounted &&
      epoch == _epoch &&
      identical(api, widget.api) &&
      accountKey == widget.account.key &&
      projectId == widget.project.id;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(l10n.compareVersionsTitle)),
    body: gestureSafe(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _controls(context),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _content(context)),
        ],
      ),
    ),
  );

  Widget _controls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _refField(
        _from,
        key: const Key('compare-from'),
        label: l10n.baseVersionFrom,
        pickerTitle: l10n.selectBaseBranch,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 10),
      _refField(
        _to,
        key: const Key('compare-to'),
        label: l10n.compareVersionTo,
        pickerTitle: l10n.selectCompareBranch,
        textInputAction: TextInputAction.done,
      ),
      const SizedBox(height: 12),
      Text(l10n.comparisonMethod, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          ChoiceChip(
            key: const Key('compare-mode-merge-base'),
            label: Text(l10n.compareFromMergeBase),
            selected: !_straight,
            onSelected: (_) => _setStraight(false),
          ),
          ChoiceChip(
            key: const Key('compare-mode-direct'),
            label: Text(l10n.compareDirectFromTo),
            selected: _straight,
            onSelected: (_) => _setStraight(true),
          ),
        ],
      ),
      if (_validation != null) ...[
        const SizedBox(height: 8),
        Text(
          _validation!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('compare-submit'),
        onPressed: _loading ? null : _compare,
        icon: const Icon(Icons.compare_arrows),
        label: Text(l10n.compareAction),
      ),
    ],
  );

  Widget _refField(
    TextEditingController controller, {
    required Key key,
    required String label,
    required String pickerTitle,
    required TextInputAction textInputAction,
  }) => TextField(
    key: key,
    controller: controller,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: textInputAction,
    onChanged: (_) => _controlsChanged(),
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Icons.commit),
      suffixIcon: IconButton(
        tooltip: pickerTitle,
        onPressed: () => _pickBranch(controller, pickerTitle),
        icon: const Icon(Icons.alt_route),
      ),
    ),
  );

  Widget _content(BuildContext context) {
    if (_loading) {
      return Center(child: Text(l10n.comparingVersions));
    }
    if (_error != null) {
      final spec = _errorSpec;
      return ListView(
        children: [
          FailureNotice(
            _error!,
            account: widget.account,
            resourceLabel:
                '${widget.project.path} · ${spec?.from ?? ''}…${spec?.to ?? ''}',
            onRetry: _compare,
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }
    final result = _result;
    if (result == null) {
      return EmptyState(l10n.selectTwoVersionsToCompare, icon: Icons.compare_arrows);
    }
    if (result.sameRef) {
      return EmptyState(l10n.versionsIdenticalNoDiff, icon: Icons.done_all);
    }
    final spec = _resultSpec!;
    return DefaultTabController(
      key: ValueKey('compare-result-${spec.storageKey}'),
      length: 2,
      child: Column(
        children: [
          if (result.timeout) _timeoutNotice(context),
          TabBar(
            tabs: [
              Tab(child: _tabLabel(l10n.commits, result.commits.length)),
              Tab(child: _tabLabel(l10n.compareFilesSection, result.diffs.length)),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _commitList(result.commits, spec),
                _fileList(result, spec),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeoutNotice(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.tertiaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.timer_off_outlined, size: 20),
        SizedBox(width: 10),
        Expanded(child: Text(l10n.compareTimeoutCommitsComplete)),
      ],
    ),
  );

  Widget _tabLabel(String label, int count) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Text(label), const SizedBox(width: 6), _CountBadge(count)],
  );

  Widget _commitList(List<Json> commits, _CompareSpec spec) {
    if (commits.isEmpty) {
      return ListView(
        children: [EmptyState(l10n.compareNoCommits, icon: Icons.commit)],
      );
    }
    return ListView.builder(
      key: PageStorageKey('compare-commits/${spec.storageKey}'),
      itemCount: commits.length,
      itemBuilder: (context, index) {
        final commit = commits[index];
        final id = valueText(
          commit,
          'short_id',
          shortSha(valueText(commit, 'id')),
        );
        final title = valueText(
          commit,
          'title',
          valueText(commit, 'message', l10n.noCommitTitle),
        );
        final author = valueText(commit, 'author_name');
        return ListTile(
          key: ValueKey('compare-commit-$index'),
          leading: const Icon(Icons.commit),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [if (id.isNotEmpty) id, if (author.isNotEmpty) author].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _fileList(_CompareResult result, _CompareSpec spec) {
    if (result.diffs.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            result.timeout
                ? l10n.compareTimeoutNoFileDiffs
                : l10n.noDisplayableTextDiffInstance,
            icon: result.timeout
                ? Icons.timer_off_outlined
                : Icons.difference_outlined,
          ),
        ],
      );
    }
    return ListView.builder(
      key: PageStorageKey('compare-files/${spec.storageKey}'),
      itemCount: result.diffs.length,
      itemBuilder: (context, index) {
        final file = result.diffs[index];
        final path = _fileTitle(file);
        final detail = _fileDetail(file);
        return ListTile(
          key: ValueKey('compare-file-$index'),
          leading: Icon(_fileIcon(file)),
          title: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: detail.isEmpty ? null : Text(detail),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      _CompareDiffPage(account: widget.account, file: file),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

final class _CompareSpec {
  const _CompareSpec({
    required this.from,
    required this.to,
    required this.straight,
  });

  final String from;
  final String to;
  final bool straight;

  String get storageKey =>
      '${Uri.encodeComponent(from)}/${Uri.encodeComponent(to)}/${straight ? 'direct' : 'merge-base'}';
}

final class _CompareResult {
  const _CompareResult({
    required this.commits,
    required this.diffs,
    required this.timeout,
    required this.sameRef,
  });

  factory _CompareResult.fromJson(Json value) {
    List<Json> objects(String key) {
      final raw = value[key];
      if (raw is! List<dynamic>) throw const FormatException('Missing list');
      final output = <Json>[];
      for (final item in raw) {
        if (item is! Json) throw const FormatException('Invalid list item');
        output.add(Map<String, dynamic>.unmodifiable(item));
      }
      return List<Json>.unmodifiable(output);
    }

    bool flag(String key) {
      final raw = value[key];
      if (raw == null) return false;
      if (raw is! bool) throw const FormatException('Invalid flag');
      return raw;
    }

    return _CompareResult(
      commits: objects('commits'),
      diffs: objects('diffs'),
      timeout: flag('compare_timeout'),
      sameRef: flag('compare_same_ref'),
    );
  }

  final List<Json> commits;
  final List<Json> diffs;
  final bool timeout;
  final bool sameRef;
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text('$count', style: Theme.of(context).textTheme.labelSmall),
  );
}

String _fileTitle(Json file) {
  final oldPath = valueText(file, 'old_path');
  final newPath = valueText(file, 'new_path');
  if (file['renamed_file'] == true &&
      oldPath.isNotEmpty &&
      newPath.isNotEmpty &&
      oldPath != newPath) {
    return '$oldPath → $newPath';
  }
  if (file['deleted_file'] == true && oldPath.isNotEmpty) return oldPath;
  if (newPath.isNotEmpty) return newPath;
  if (oldPath.isNotEmpty) return oldPath;
  return l10n.unnamedFile;
}

String _fileDetail(Json file) {
  final labels = <String>[];
  if (file['new_file'] == true) labels.add(l10n.added);
  if (file['renamed_file'] == true) labels.add(l10n.renamed);
  if (file['deleted_file'] == true) labels.add(l10n.diffStatusDeleted);
  if (file['too_large'] == true) labels.add(l10n.diffTooLarge);
  if (file['collapsed'] == true) labels.add(l10n.collapsedByGitlab);
  if (labels.isEmpty && valueText(file, 'diff').isEmpty) {
    labels.add(l10n.noTextDiff);
  }
  return labels.join(' · ');
}

IconData _fileIcon(Json file) {
  if (file['deleted_file'] == true) return Icons.delete_outline;
  if (file['renamed_file'] == true) return Icons.drive_file_rename_outline;
  if (file['new_file'] == true) return Icons.note_add_outlined;
  return Icons.difference_outlined;
}

class _CompareDiffPage extends StatefulWidget {
  const _CompareDiffPage({required this.account, required this.file});

  final Account account;
  final Json file;

  @override
  State<_CompareDiffPage> createState() => _CompareDiffPageState();
}

class _CompareDiffPageState extends State<_CompareDiffPage> {
  static const _maxDisplayedLineCharacters = 2000;

  List<DiffLine>? _lines;
  ApiFailure? _error;
  String? _notice;
  bool _loading = false;
  bool _hasTruncatedLines = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    if (widget.file['too_large'] == true) {
      _notice = l10n.fileDiffTooLargeForApp;
      return;
    }
    if (widget.file['collapsed'] == true) {
      _notice = l10n.fileDiffCollapsedNoContent;
      return;
    }
    final source = valueText(widget.file, 'diff');
    if (source.isEmpty) {
      _notice = l10n.noDisplayableTextDiffNoContent;
      return;
    }
    _loading = true;
    unawaited(_parse(source));
  }

  Future<void> _parse(String source) async {
    final epoch = ++_epoch;
    try {
      final lines = await compute(parseUnifiedDiff, source);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _lines = lines;
        _hasTruncatedLines = lines.any(
          (line) => line.text.length > _maxDisplayedLineCharacters,
        );
        _loading = false;
      });
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = const ApiFailure(FailureKind.invalidResponse);
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_fileTitle(widget.file))),
    body: gestureSafe(_body(context)),
  );

  Widget _body(BuildContext context) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 12),
            Text(l10n.preparingDiff),
          ],
        ),
      );
    }
    if (_error != null) {
      return ListView(
        children: [
          FailureNotice(
            _error!,
            account: widget.account,
            resourceLabel: _fileTitle(widget.file),
            onSwitchAccount: endSessionFrom(context),
          ),
        ],
      );
    }
    if (_notice != null) {
      return EmptyState(_notice!, icon: Icons.description_outlined);
    }
    final lines = _lines ?? const <DiffLine>[];
    if (lines.isEmpty) {
      return EmptyState(l10n.noDiffLinesToDisplay, icon: Icons.difference);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasTruncatedLines)
          Container(
            key: const ValueKey('compare-line-truncated-notice'),
            color: Theme.of(context).colorScheme.tertiaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(l10n.diffLineTruncated),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(1);
              final width = math.max(constraints.maxWidth, 760 * textScale);
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  height: constraints.maxHeight,
                  child: SelectionArea(
                    child: ListView.builder(
                      itemCount: lines.length,
                      itemBuilder: (context, index) =>
                          _diffLine(context, lines[index], index),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _displayText(String value) {
    if (value.length <= _maxDisplayedLineCharacters) return value;
    var end = _maxDisplayedLineCharacters;
    final last = value.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return '${value.substring(0, end)}…';
  }

  Widget _diffLine(BuildContext context, DiffLine line, int index) {
    final scheme = Theme.of(context).colorScheme;
    final colors = WorkshopColors.of(context);
    final background = switch (line.kind) {
      'add' => colors.diffAdded.withValues(alpha: .16),
      'remove' => colors.diffRemoved.withValues(alpha: .16),
      'hunk' => scheme.surfaceContainerHighest,
      _ => null,
    };
    final marker = switch (line.kind) {
      'add' => '+',
      'remove' => '−',
      _ => ' ',
    };
    const numberStyle = TextStyle(
      fontFamily: codeFontFamily,
      fontFamilyFallback: ['Menlo', 'monospace'],
      fontSize: 12,
    );
    const codeStyle = TextStyle(
      fontFamily: codeFontFamily,
      fontFamilyFallback: ['Menlo', 'monospace'],
      fontSize: 13,
      height: 1.45,
    );
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              '${line.oldLine ?? ''}',
              key: ValueKey('compare-old-$index'),
              style: numberStyle,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${line.newLine ?? ''}',
              key: ValueKey('compare-new-$index'),
              style: numberStyle,
            ),
          ),
          SizedBox(width: 20, child: Text(marker, style: codeStyle)),
          Expanded(
            child: Text(
              _displayText(line.text),
              key: ValueKey('compare-text-$index'),
              style: codeStyle,
            ),
          ),
        ],
      ),
      ),
    );
  }
}
