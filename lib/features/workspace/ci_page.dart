import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../ai/ai_chat_page.dart';
import '../ai/ai_chat_session.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/job_trace.dart';
import '../../core/models.dart';
import '../../core/rate_budget.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../shared/external_link.dart';
import '../../shared/motion.dart';
import '../../shared/resource_share.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/cache_freshness.dart';
import '../../shared/workspace_ui.dart';
import 'commit_page.dart';
import 'records_feed.dart';
import 'pipeline_graph_page.dart';
import 'work_item_page.dart';
import '../../shared/artifact_storage.dart';
import '../../shared/theme.dart';
import '../../l10n/l10n.dart';
export '../../shared/artifact_storage.dart';

class _CiVariableEntry {
  _CiVariableEntry({
    String key = '',
    String value = '',
  })  : keyController = TextEditingController(text: key),
        valueController = TextEditingController(text: value);

  final TextEditingController keyController;
  final TextEditingController valueController;
  String variableType = 'env_var';
  String? keyError;

  void dispose() {
    keyController.dispose();
    valueController.dispose();
  }
}

class RunPipelineDialog extends StatefulWidget {
  const RunPipelineDialog({
    super.key,
    required this.account,
    required this.api,
    required this.project,
  });

  final Account account;
  final GitLabApi api;
  final Project project;

  @override
  State<RunPipelineDialog> createState() => _RunPipelineDialogState();
}

class _RunPipelineDialogState extends State<RunPipelineDialog> {
  late final TextEditingController _refController;
  final _variables = <_CiVariableEntry>[];
  String? _refError;
  bool _submitting = false;
  String? _submitError;
  static final _validKeyRegex = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');

  @override
  void initState() {
    super.initState();
    final defaultBranch = widget.project.defaultBranch?.trim();
    _refController = TextEditingController(
      text: (defaultBranch != null && defaultBranch.isNotEmpty)
          ? defaultBranch
          : 'main',
    );
  }

  @override
  void dispose() {
    _refController.dispose();
    for (final v in _variables) {
      v.dispose();
    }
    super.dispose();
  }

  void _addVariable() {
    setState(() {
      _variables.add(_CiVariableEntry());
    });
  }

  void _removeVariable(int index) {
    final removed = _variables.removeAt(index);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _refError = null;
      _submitError = null;
      for (final v in _variables) {
        v.keyError = null;
      }
    });

    final ref = _refController.text.trim();
    if (ref.isEmpty) {
      setState(() => _refError = l10n.enterBranchOrTagName);
      return;
    }

    var hasError = false;
    final seenKeys = <String>{};
    final variablesToSubmit = <Map<String, String>>[];

    for (var i = 0; i < _variables.length; i++) {
      final entry = _variables[i];
      final key = entry.keyController.text.trim();
      final val = entry.valueController.text;

      // 空值過濾: 如果 key 和 value 均為空，則直接忽略該列
      if (key.isEmpty && val.isEmpty) {
        continue;
      }

      if (key.isEmpty) {
        entry.keyError = l10n.variableNameEmpty;
        hasError = true;
        continue;
      }

      if (!_validKeyRegex.hasMatch(key)) {
        entry.keyError = l10n.variableNameInvalidFormat;
        hasError = true;
        continue;
      }

      if (seenKeys.contains(key)) {
        entry.keyError = l10n.duplicateVariableName;
        hasError = true;
        continue;
      }
      seenKeys.add(key);

      variablesToSubmit.add({
        'key': key,
        'value': val,
        'variable_type': entry.variableType,
      });
    }

    if (hasError) {
      setState(() {});
      return;
    }

    setState(() => _submitting = true);
    try {
      final response = await widget.api.createPipeline(
        widget.project.id,
        ref,
        variables: variablesToSubmit.isNotEmpty ? variablesToSubmit : null,
      );
      final id = requiredInt(response, 'id');
      if (mounted) {
        Navigator.of(context).pop(id);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitError = safeFailure(e).title;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      scrollable: true,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.play_circle_outline),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.runPipeline,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            widget.project.path,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('editor-ref'),
              controller: _refController,
              decoration: InputDecoration(
                labelText: l10n.branchOrTag,
                hintText: l10n.branchOrTagExample,
                helperText: l10n.pipelineRefDeployWarning,
                helperMaxLines: 2,
                errorText: _refError,
                prefixIcon: const Icon(Icons.alt_route),
              ),
              onChanged: (_) {
                if (_refError != null) {
                  setState(() => _refError = null);
                }
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  l10n.ciVariablesCount(_variables.length),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  key: const Key('add-ci-variable'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: _submitting ? null : _addVariable,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.addCiVariable),
                ),
              ],
            ),
            if (_variables.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.noCustomCiVariables,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                ),
              ),
            for (var i = 0; i < _variables.length; i++) ...[
              Card(
                key: ObjectKey(_variables[i]),
                margin: const EdgeInsets.symmetric(vertical: 6),
                color: colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            l10n.ciVariableNumber(i + 1),
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            key: ValueKey('ci-var-remove-$i'),
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: l10n.deleteCiVariable,
                            onPressed: _submitting ? null : () => _removeVariable(i),
                          ),
                        ],
                      ),
                      TextField(
                        key: ValueKey('ci-var-key-$i'),
                        controller: _variables[i].keyController,
                        decoration: InputDecoration(
                          labelText: l10n.variableNameKey,
                          hintText: 'VARIABLE_NAME',
                          errorText: _variables[i].keyError,
                        ),
                        onChanged: (_) {
                          if (_variables[i].keyError != null) {
                            setState(() => _variables[i].keyError = null);
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: ValueKey('ci-var-val-$i'),
                        controller: _variables[i].valueController,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: l10n.variableValueLabel,
                          hintText: l10n.variableValue,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        key: ValueKey('ci-var-type-$i'),
                        initialValue: _variables[i].variableType,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.variableType,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'env_var',
                            child: Text(
                              l10n.variableTypeEnvVar,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'file',
                            child: Text(
                              l10n.variableTypeFile,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        onChanged: _submitting
                            ? null
                            : (val) {
                                if (val != null) {
                                  setState(() => _variables[i].variableType = val);
                                }
                              },
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_submitError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _submitError!,
                  style: TextStyle(
                    color: colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          key: const Key('editorSave'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(l10n.runCiSubmit),
        ),
      ],
    );
  }
}

class PipelinesTab extends StatefulWidget {
  const PipelinesTab({super.key, required this.account, required this.api, required this.project});
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  State<PipelinesTab> createState() => _PipelinesTabState();
}

final class _PipelineActorLoader {
  _PipelineActorLoader({required this.api, required this.projectId});

  final GitLabApi api;
  final int projectId;
  final _cache = <int, Future<Json?>>{};
  final _queue = <({int pipelineId, Completer<Json?> completer})>[];
  var _active = 0;
  var _disposed = false;

  Future<Json?> load(int pipelineId) {
    if (_disposed) return Future<Json?>.value();
    return _cache.putIfAbsent(pipelineId, () {
      final completer = Completer<Json?>();
      _queue.add((pipelineId: pipelineId, completer: completer));
      _drain();
      return completer.future;
    });
  }

  void _drain() {
    while (!_disposed && _active < 4 && _queue.isNotEmpty) {
      final request = _queue.removeAt(0);
      _active++;
      unawaited(_load(request).whenComplete(() {
        _active--;
        _drain();
      }));
    }
  }

  Future<void> _load(({int pipelineId, Completer<Json?> completer}) request) async {
    Json? actor;
    try {
      final detail = await api.record(
        ['projects', '$projectId', 'pipelines', '${request.pipelineId}'],
      );
      final user = valueObject(detail, 'user');
      if (valueInt(detail, 'id') == request.pipelineId &&
          PersonChip.of(user, author: false) != null) {
        actor = user;
      }
    } catch (_) {
      // Executor enrichment is optional; the pipeline summary remains usable.
    }
    if (actor == null) {
      unawaited(_cache.remove(request.pipelineId) ?? Future<Json?>.value());
    }
    if (!request.completer.isCompleted) {
      request.completer.complete(_disposed ? null : actor);
    }
  }

  void dispose() {
    _disposed = true;
    for (final request in _queue) {
      if (!request.completer.isCompleted) request.completer.complete(null);
    }
    _queue.clear();
    _cache.clear();
  }
}

class _PipelineActorChip extends StatefulWidget {
  const _PipelineActorChip({required this.loader, required this.pipelineId});

  final _PipelineActorLoader loader;
  final int pipelineId;

  @override
  State<_PipelineActorChip> createState() => _PipelineActorChipState();
}

class _PipelineActorChipState extends State<_PipelineActorChip> {
  Json? _actor;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PipelineActorChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.loader, widget.loader) ||
        oldWidget.pipelineId != widget.pipelineId) {
      _actor = null;
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    unawaited(widget.loader.load(widget.pipelineId).then((actor) {
      if (!mounted || generation != _generation || actor == null) return;
      setState(() => _actor = actor);
    }));
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actor = _actor;
    return actor == null
        ? const SizedBox.shrink()
        : PersonChip.of(actor, author: false) ?? const SizedBox.shrink();
  }
}

class _PipelinesTabState extends State<PipelinesTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _refInput = TextEditingController();
  late _PipelineActorLoader _actors;
  var _ownerGeneration = 0;
  String _state = '', _ref = '';

  @override
  void initState() {
    super.initState();
    _actors = _newActorLoader();
  }

  _PipelineActorLoader _newActorLoader() => _PipelineActorLoader(
    api: widget.api,
    projectId: widget.project.id,
  );

  @override
  void didUpdateWidget(covariant PipelinesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        !identical(oldWidget.api, widget.api)) {
      _actors.dispose();
      _actors = _newActorLoader();
      _ownerGeneration++;
    }
  }

  Future<ApiPage<Json>> _loadPipelines(Uri? next) async {
    final api = widget.api, projectId = widget.project.id;
    final state = _state, ref = _ref;
    return api.records(['projects', '$projectId', 'pipelines'],
      query: {'order_by': 'id', 'sort': 'desc', if (state.isNotEmpty) 'status': state, if (ref.isNotEmpty) 'ref': ref}, next: next);
  }
  Future<void> _open(int id) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PipelinePage(
      account: widget.account, api: widget.api, project: widget.project, id: id)));
    if (mounted) { await _feed.currentState?.refresh(); }
  }
  Future<void> _run() async {
    final id = await showDialog<int>(
      context: context,
      builder: (context) => RunPipelineDialog(
        account: widget.account,
        api: widget.api,
        project: widget.project,
      ),
    );
    if (id != null && mounted) {
      await _feed.currentState?.refresh();
      await _open(id);
    }
  }
  @override
  void dispose() {
    _actors.dispose();
    _refInput.dispose();
    super.dispose();
  }

  Widget _controls(BuildContext context) {
    final gutter = feedGutter(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: EdgeInsets.fromLTRB(gutter, 12, gutter - 4, 6), child: Row(children: [
        Expanded(child: TextField(controller: _refInput,
          decoration: InputDecoration(hintText: l10n.filterByBranch, prefixIcon: const Icon(Icons.alt_route),
            suffixIcon: _ref.isEmpty ? null : IconButton(tooltip: l10n.clearBranchFilter, icon: const Icon(Icons.close, size: 18),
              onPressed: () { _refInput.clear(); setState(() => _ref = ''); })),
          textInputAction: TextInputAction.search, onSubmitted: (value) => setState(() => _ref = value.trim()))),
        const SizedBox(width: 4), IconButton(tooltip: l10n.runPipeline, onPressed: widget.project.archived == true ? null : _run,
          icon: const Icon(Icons.play_circle_outline)),
      ])),
      SingleChildScrollView(scrollDirection: Axis.horizontal, padding: EdgeInsets.symmetric(horizontal: gutter),
        child: Row(children: [for (final e in {'': l10n.filterAll, 'running': l10n.statusRunning, 'failed': l10n.statusFailed, 'success': l10n.statusPassed}.entries)
          Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(e.value),
            selected: _state == e.key, showCheckmark: false, onSelected: (_) => setState(() => _state = e.key)))])),
    ]);
  }

  @override
  Widget build(BuildContext context) => RecordsFeed(key: _feed,
      identity: '${widget.account.key}/${widget.project.id}/$_ownerGeneration/pipelines/$_state/$_ref', storageId: 'pipelines',
      empty: l10n.noMatchingPipelines, emptyIcon: Icons.account_tree_outlined, grouped: true,
      account: widget.account, resourceLabel: '${widget.project.path} · Pipeline',
      onSwitchAccount: endSessionFrom(context),
      leading: (context, _) => _controls(context),
      cached: ({required bool fresh, required bool background}) => widget.api.cachedRecords(
        ['projects', '${widget.project.id}', 'pipelines'], query: {
          'order_by': 'id', 'sort': 'desc',
          if (_state.isNotEmpty) 'status': _state, if (_ref.isNotEmpty) 'ref': _ref,
        }, fresh: fresh, background: background),
      load: _loadPipelines,
      itemBuilder: (context, value) {
        final id = requiredInt(value, 'id');
        final actor = PersonChip.of(valueObject(value, 'user'), author: false) ??
            _PipelineActorChip(loader: _actors, pipelineId: id);
        return pipelineRow(context, value, actor: actor, onTap: () => _open(id));
      },
    );
}

/// Jobs in pipeline order: stages in the order their first job was created,
/// then the latest attempt of each job where that job first appeared. Expects
/// retried attempts too (`include_retried=true`): a retry gets a new, higher
/// ID, and only the original attempt still shows where its stage belongs.
List<Json> stageOrder(List<Json> jobs) {
  final byId = [...jobs]..sort((a, b) => valueInt(a, 'id').compareTo(valueInt(b, 'id')));
  final stages = <String, Map<String, Json>>{};
  for (final job in byId) {
    // A job without a stage groups under an empty key, never a stage name.
    final attempts = stages.putIfAbsent(valueText(job, 'stage'), () => <String, Json>{});
    // Replacing a value keeps the key's first position.
    attempts[valueText(job, 'name', '#${valueInt(job, 'id')}')] = job;
  }
  return [for (final attempts in stages.values) ...attempts.values];
}

/// `83` → `1 分 23 秒`; hours roll over for long jobs.
String formatDuration(int seconds) {
  if (seconds < 60) return l10n.durationSeconds(seconds);
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  if (h > 0) return l10n.durationHoursMinutes(h, m);
  return s == 0 ? l10n.durationMinutes(m) : l10n.durationMinutesSeconds(m, s);
}

String pipelineSourceLabel(String source) => switch (source) {
  'push' => l10n.pipelineSourcePush,
  'merge_request_event' => l10n.mergeRequestLabel,
  'schedule' => l10n.pipelineSourceSchedule,
  'web' => l10n.pipelineSourceManual,
  'api' => 'API',
  'trigger' => l10n.pipelineSourceTrigger,
  'pipeline' || 'parent_pipeline' => l10n.pipelineSourceUpstream,
  'external' || 'external_pull_request_event' => l10n.pipelineSourceExternal,
  'chat' => 'ChatOps',
  _ => source,
};

/// The merge request IID a merge request pipeline ran for, from its
/// `refs/merge-requests/<iid>/head` ref (`/merge` and `/train` for merged
/// results and merge trains), or null for a branch or tag.
int? mergeRequestIidOfRef(String ref) {
  final match = RegExp(r'^refs/merge-requests/(\d+)/(?:head|merge|train)$').firstMatch(ref);
  final iid = match == null ? null : int.tryParse(match.group(1)!);
  return iid != null && iid > 0 ? iid : null;
}

/// One pipeline as a dense row: status, name or number, ref, commit and age.
Widget pipelineRow(BuildContext context, Json value, {required VoidCallback onTap, String? project, Widget? actor}) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  final source = pipelineSourceLabel(valueText(value, 'source'));
  final name = valueText(value, 'name');
  final number = valueInt(value, 'iid') > 0 ? '#${valueInt(value, 'iid')}' : '#${valueInt(value, 'id')}';
  return SemanticButton(
    label: pipelineCardLabel(value), onTap: onTap,
    child: InkWell(onTap: onTap, child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: StatusBadge(valueText(value, 'status'))),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: Text(name.isNotEmpty ? name : 'Pipeline $number', maxLines: 1,
              overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontSize: 15))),
          ]),
          if (project != null && project.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(project, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
          const SizedBox(height: 6),
          Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ?actor ?? PersonChip.of(valueObject(value, 'user'), author: false),
            MetaChip(valueText(value, 'ref'), icon: Icons.alt_route, mono: true),
            MetaChip(shortSha(valueText(value, 'sha')), icon: Icons.commit, mono: true),
            if (name.isNotEmpty) MetaChip(number, mono: true),
            if (source.isNotEmpty) MetaChip(source, icon: Icons.bolt_outlined),
            MetaChip(relativeDate(valueText(value, 'updated_at')), icon: Icons.schedule_outlined),
          ]),
        ])),
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.chevron_right, size: 18, color: muted)),
      ]),
    )),
  );
}

class PipelinePage extends StatefulWidget {
  const PipelinePage({super.key, required this.account, required this.api, required this.project, required this.id});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int id;
  @override
  PipelinePageState createState() => PipelinePageState();
}
class PipelinePageState extends State<PipelinePage> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _testsKey = GlobalKey<PipelineTestsViewState>();
  final _chrome = ScrollChromeController();
  int _generation = 0;
  int _readEpoch = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  ValueListenable<TickerModeData>? _tickerMode;
  bool _backgroundEnabled = true;
  bool _resumeWhenVisible = false;
  bool _current(int generation) => mounted && !widget.api.isClosed && generation == _generation;
  bool _readCurrent(int generation, int readEpoch) =>
      _current(generation) && readEpoch == _readEpoch;
  bool _canApplyRead(int generation, int readEpoch, {required bool background}) {
    if (!_readCurrent(generation, readEpoch)) return false;
    if (background && !_backgroundEnabled) {
      _stale = true;
      _resumeWhenVisible = true;
      return false;
    }
    return true;
  }
  Json? get data => _data;
  ApiFailure? get error => _error;
  DateTime? get fetchedAt => _fetchedAt;
  bool get stale => _stale;
  bool get revalidating => _revalidating;
  FailureKind? get backgroundFailure => _backgroundFailure;
  DateTime? get backgroundRetryAt => _backgroundRetryAt;

  // Metadata shown from an earlier read: say so while it is refreshed in the
  // background or after that refresh failed. Fresh data gets no strip.
  DateTime? get _freshnessAt => _data == null || _loading || _error != null ||
      !(_stale || _revalidating || _backgroundFailure != null) ? null : _fetchedAt;
  void _updateTickerMode() {
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_tickerModeChanged);
      _tickerMode = mode;
      mode.addListener(_tickerModeChanged);
    }
    _tickerModeChanged();
  }
  void _tickerModeChanged() {
    _backgroundEnabled = _tickerMode!.value.enabled;
    if (!_backgroundEnabled && _revalidating) _resumeWhenVisible = true;
    if (_backgroundEnabled) _startRevalidation(_generation);
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    _updateTickerMode();
  }
  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }
  void _dismissRoutes() {
    final navigator = _navigator, routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (!route.isActive) continue;
        navigator.popUntil((candidate) => candidate == route || candidate.isFirst);
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }
  @override
  void didUpdateWidget(covariant PipelinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key || oldWidget.project.id != widget.project.id ||
        oldWidget.id != widget.id || !identical(oldWidget.api, widget.api)) {
      _generation++;
      _readEpoch++;
      _dismissRoutes();
      _data = null;
      _error = null;
      _fetchedAt = null;
      _stale = false;
      _revalidating = false;
      _backgroundFailure = null;
      _backgroundRetryAt = null;
      _resumeWhenVisible = false;
      _busy = false;
      _loading = false;
      unawaited(_load());
    }
  }
  @override
  void dispose() {
    _generation++;
    _readEpoch++;
    _dismissRoutes();
    _tickerMode?.removeListener(_tickerModeChanged);
    _chrome.dispose();
    super.dispose();
  }
  Json? _data;
  ApiFailure? _error;
  DateTime? _fetchedAt;
  bool _stale = false, _revalidating = false;
  FailureKind? _backgroundFailure;
  DateTime? _backgroundRetryAt;
  bool _busy = false, _loading = false;
  @override
  void initState() { super.initState(); unawaited(_load()); }
  bool _revoked(ApiFailure failure) => switch (failure.kind) {
    FailureKind.unauthenticated || FailureKind.forbidden || FailureKind.invisible => true,
    _ => false,
  };
  Future<CachedRead<Json>?> _read(
    PipelinePage owner,
    int generation, {
    required int readEpoch,
    required bool fresh,
    required bool background,
  }) async {
    Future<CachedRead<Json>> readPage(bool force, {bool quiet = false}) => CachedRead.run(
      () => owner.api.cachedRecord(
        ['projects', '${owner.project.id}', 'pipelines', '${owner.id}'],
        fresh: force,
        background: background,
      ),
      mayStart: () => _readCurrent(generation, readEpoch) &&
          (!background || _backgroundEnabled),
      waitForQuiet: quiet,
    );
    var read = await readPage(fresh);
    if (!_canApplyRead(generation, readEpoch, background: background)) return null;
    if (read.superseded) {
      read = await readPage(true);
      if (!_canApplyRead(generation, readEpoch, background: background)) return null;
      if (read.superseded) {
        read = await readPage(true, quiet: true);
        if (!_canApplyRead(generation, readEpoch, background: background)) return null;
      }
      if (read.superseded) throw const ApiFailure(FailureKind.cancelled);
    }
    return read.dropped ? null : read;
  }
  void _apply(CachedRead<Json> read) {
    _data = read.value;
    _fetchedAt = read.fetchedAt;
    _stale = read.stale;
  }
  void _withdraw() {
    _data = null;
    _fetchedAt = null;
    _stale = false;
  }
  Future<void> _load({bool fresh = false}) async {
    if (_loading || !mounted) { return; }
    final owner = widget, generation = _generation, readEpoch = ++_readEpoch;
    setState(() {
      _loading = true;
      _error = null;
      _revalidating = false;
      _backgroundFailure = null;
      _backgroundRetryAt = null;
      _resumeWhenVisible = false;
    });
    try {
      final read = await _read(
        owner,
        generation,
        readEpoch: readEpoch,
        fresh: fresh,
        background: false,
      );
      if (!_readCurrent(generation, readEpoch)) return;
      if (read == null) {
        if (_data == null) {
          setState(() => _error = const ApiFailure(FailureKind.cancelled));
        }
        return;
      }
      setState(() { _apply(read); _loading = false; });
      _startRevalidation(generation, readEpoch: readEpoch);
    } catch (e) {
      if (_readCurrent(generation, readEpoch)) {
        final failure = safeFailure(e);
        setState(() { _error = failure; if (_revoked(failure)) _withdraw(); });
      }
    } finally {
      if (_readCurrent(generation, readEpoch) && _loading) {
        setState(() => _loading = false);
      }
    }
  }
  void _startRevalidation(int generation, {int? readEpoch}) {
    final epoch = readEpoch ?? _readEpoch;
    if (!_readCurrent(generation, epoch) || !_backgroundEnabled || !_stale || _revalidating ||
        _backgroundFailure != null || _loading) {
      return;
    }
    setState(() { _revalidating = true; _resumeWhenVisible = false; });
    unawaited(_revalidate(widget, generation, epoch));
  }
  Future<void> _revalidate(PipelinePage owner, int generation, int readEpoch) async {
    try {
      final read = await _read(
        owner,
        generation,
        readEpoch: readEpoch,
        fresh: true,
        background: true,
      );
      if (_canApplyRead(generation, readEpoch, background: true) && read != null) {
        setState(() => _apply(read));
      }
    } catch (e) {
      if (!_readCurrent(generation, readEpoch)) return;
      final failure = safeFailure(e);
      if (!_revoked(failure) && !_canApplyRead(generation, readEpoch, background: true)) return;
      setState(() {
        if (_revoked(failure)) {
          _withdraw();
          _error = failure;
        } else {
          _backgroundFailure = failure.kind;
          _backgroundRetryAt = failure.retryAt;
        }
      });
    } finally {
      if (_readCurrent(generation, readEpoch)) {
        setState(() => _revalidating = false);
        if (_resumeWhenVisible && _backgroundEnabled) {
          _startRevalidation(generation, readEpoch: readEpoch);
        }
      }
    }
  }
  void _openOwned(int generation, Widget Function(PipelinePage owner) page) {
    final owner = widget;
    if (!_current(generation) || owner.api.isClosed) return;
    final route = MaterialPageRoute<void>(builder: (_) => page(owner));
    _ownRoute(route);
    unawaited(Navigator.push(context, route));
  }
  void _openGraph() {
    final owner = widget;
    final route = MaterialPageRoute<void>(builder: (_) => PipelineGraphPage(
      account: owner.account, api: owner.api, project: owner.project, pipelineId: owner.id));
    _ownRoute(route);
    unawaited(Navigator.push(context, route));
  }
  Future<void> _refreshJobs() async {
    final owner = widget, generation = _generation, feed = _feed.currentState;
    if (!_current(generation) || _data == null) return;
    if (feed != null) {
      await feed.refresh();
      return;
    }
    // TabBarView disposes the jobs feed while Tests is selected. Refresh its
    // canonical cache too, so returning to Jobs cannot reuse the old value.
    try {
      await owner.api.cachedRecords(
        ['projects', '${owner.project.id}', 'pipelines', '${owner.id}', 'jobs'],
        query: {'include_retried': 'true', 'per_page': '100'},
        fresh: true,
      );
    } catch (e) {
      if (mounted && _current(generation)) showFailure(context, e);
    }
  }
  Future<void> _openJob(int id) async {
    final owner = widget, generation = _generation;
    final route = MaterialPageRoute<void>(builder: (_) => JobLogPage(
      account: owner.account, api: owner.api, project: owner.project, id: id));
    _ownRoute(route);
    await Navigator.push(context, route);
    // The job route stays open across retries and completes only on real back.
    if (!_current(generation)) { return; }
    await _load(fresh: true);
    if (_current(generation)) {
      await _refreshJobs();
      if (_current(generation)) await _testsKey.currentState?.refresh();
    }
  }
  Future<void> _action(String action) async {
    if (_busy) { return; }
    final owner = widget, generation = _generation;
    final label = action == 'retry' ? l10n.retryFailedJobs : action == 'cancel' ? l10n.cancelPipeline : l10n.deletePipeline;
    if (!await confirmAction(context, l10n.confirmActionQuestion(label), '${owner.project.path}\nPipeline #${owner.id}',
      requiredText: action == 'delete' ? '${owner.id}' : null, onRoute: _ownRoute)) { return; }
    if (!_current(generation)) { return; }
    setState(() => _busy = true);
    try {
      if (action == 'delete') {
        await owner.api.deletePipeline(owner.project.id, owner.id);
        if (mounted && _current(generation)) { Navigator.pop(context); }
        return;
      }
      await owner.api.pipelineAction(owner.project.id, owner.id, action);
      if (!_current(generation)) return;
      await _load(fresh: true);
      if (_current(generation)) {
        await _refreshJobs();
        if (_current(generation)) await _testsKey.currentState?.refresh();
      }
    } catch (e) { if (mounted && _current(generation)) { showFailure(context, e); } }
    finally { if (_current(generation)) { setState(() => _busy = false); } }
  }
  Future<void> _jobAction(int jobId, String action) async {
    if (_busy) { return; }
    final owner = widget, generation = _generation;
    final label = action == 'retry' ? l10n.retryJob : action == 'play' ? l10n.startManualJob : l10n.cancelJob;
    if (!await confirmAction(context, l10n.confirmActionQuestion(label), '${owner.project.path}\nJob #$jobId', onRoute: _ownRoute)) { return; }
    if (!_current(generation)) { return; }
    setState(() => _busy = true);
    try {
      await owner.api.jobAction(owner.project.id, jobId, action);
      if (!_current(generation)) return;
      unawaited(Haptics.success());
      await _load(fresh: true);
      if (_current(generation)) {
        await _refreshJobs();
        if (_current(generation)) await _testsKey.currentState?.refresh();
      }
    } catch (e) {
      if (mounted && _current(generation)) {
        unawaited(Haptics.failure());
        showFailure(context, e);
      }
    }
    finally { if (_current(generation)) { setState(() => _busy = false); } }
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final generation = _generation;
    final appBar = AppBar(primary: false,
      toolbarHeight: (MediaQuery.textScalerOf(context).scale(19) * 1.3 +
          MediaQuery.textScalerOf(context).scale(12) * 1.5 + 12).clamp(56, double.infinity),
      titleSpacing: 0, title: Column(crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, children: [
        Text(_data != null && valueInt(_data!, 'iid') > 0 ? 'Pipeline #${valueInt(_data!, 'iid')}' : 'Pipeline #${widget.id}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 19)),
        Text(widget.project.path, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]), actions: [
        ResourceShareButton(uri: widget.account.instance.projectWeb('${widget.project.path}/-/pipelines/${widget.id}'),
          ownerKey: (widget.account.key, widget.api, widget.project.id, widget.id, generation),
          isCurrent: () => _current(generation) && !widget.api.isClosed),
        IconButton(tooltip: l10n.jobDependencyGraph,
          onPressed: _openGraph,
          icon: const Icon(Icons.account_tree_outlined)),
        IconButton(tooltip: l10n.refreshAction, onPressed: _loading || _busy ? null : () async {
          final generation = _generation;
          await _load(fresh: true);
          if (_current(generation)) {
            await _refreshJobs();
            if (_current(generation)) await _testsKey.currentState?.refresh();
          }
        }, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(enabled: !_busy, tooltip: l10n.pipelineActions, onSelected: _action, itemBuilder: (_) => [
          PopupMenuItem(value: 'retry', child: Text(l10n.retryFailedJobs)),
          PopupMenuItem(value: 'cancel', child: Text(l10n.cancelPipeline)),
          PopupMenuItem(value: 'delete', child: Text(l10n.deletePipeline)),
        ]),
      ]);
    return DefaultTabController(
    length: 2,
    child: Scaffold(
      body: NotificationListener<ScrollNotification>(onNotification: _chrome.handle, child:
        StatusBarInset(child: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CollapsingChrome(visible: _chrome, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          appBar,
          if (_data != null) Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child:
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusBadge(valueText(_data!, 'status')),
              if (mergeRequestIidOfRef(valueText(_data!, 'ref')) case final iid?)
                MetaChip(valueText(_data!, 'ref'), icon: Icons.alt_route, mono: true,
                  key: const ValueKey('pipeline-ref-link'), semanticLabel: l10n.openMergeRequest(iid),
                  onTap: () => _openOwned(generation, (owner) => WorkItemPage(account: owner.account, api: owner.api,
                    project: owner.project, resource: 'merge_requests', iid: iid)))
              else
                MetaChip(valueText(_data!, 'ref'), icon: Icons.alt_route, mono: true),
              if (valueText(_data!, 'sha') case final sha when sha.isNotEmpty)
                MetaChip(shortSha(sha), icon: Icons.commit, mono: true,
                  key: const ValueKey('pipeline-sha-link'), semanticLabel: l10n.openCommit(shortSha(sha)),
                  onTap: () => _openOwned(generation, (owner) => CommitDetailPage(account: owner.account, api: owner.api,
                    project: owner.project, sha: sha))),
              // The title shows the project-scoped number; links and the API use this ID.
              if (valueInt(_data!, 'iid') > 0) MetaChip('ID ${widget.id}', icon: Icons.tag, mono: true),
              if (valueText(_data!, 'source').isNotEmpty)
                MetaChip(pipelineSourceLabel(valueText(_data!, 'source')), icon: Icons.bolt_outlined),
              if (_data!['duration'] is num)
                MetaChip(formatDuration((_data!['duration'] as num).round()), icon: Icons.timer_outlined),
              if (valueText(valueObject(_data!, 'user'), 'username').isNotEmpty)
                MetaChip('@${valueText(valueObject(_data!, 'user'), 'username')}', icon: Icons.person_outline),
              if (valueText(_data!, 'status') == 'failed')
                FilledButton.tonalIcon(
                  key: const ValueKey('pipeline-quick-retry-btn'),
                  onPressed: _busy ? null : () => _action('retry'),
                  icon: const Icon(Icons.replay, size: 16),
                  label: Text(l10n.retryThisPipeline, style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                ),
              if (const ['running', 'pending'].contains(valueText(_data!, 'status')))
                OutlinedButton.icon(
                  key: const ValueKey('pipeline-quick-cancel-btn'),
                  onPressed: _busy ? null : () => _action('cancel'),
                  icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.red),
                  label: Text(l10n.abortThisPipeline, style: TextStyle(fontSize: 12, color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                ),
            ])),
        ])),
        if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) FailureNotice(_error!, onRetry: _load, account: widget.account,
          resourceLabel: '${widget.project.path} · Pipeline #${widget.id}',
          onSwitchAccount: endSessionFrom(context, ResumeTarget(
            projectId: widget.project.id,
            projectPath: widget.project.path,
            resource: 'pipelines',
            iid: widget.id,
          ))),
        if (_freshnessAt case final fetchedAt?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: CacheFreshnessBar(
              fetchedAt: fetchedAt,
              refreshing: _revalidating,
              failure: _backgroundFailure,
              retryAt: _backgroundRetryAt,
              onRetry: () => unawaited(_load(fresh: true)),
            ),
          ),
        if (_data != null)
          TabBar(
            onTap: (_) => _chrome.show(),
            indicatorSize: TabBarIndicatorSize.tab,
            tabs: [
              Tab(text: l10n.jobsTab),
              Tab(text: l10n.testsTab),
            ],
          ),
        if (_data != null)
          Expanded(
            child: TabBarView(
              children: [
                RecordsFeed(
                  key: _feed,
                  identity: '${widget.account.key}/${widget.project.id}/pipeline/${widget.id}/jobs/$_generation',
                  empty: l10n.noJobsYet,
                  emptyIcon: Icons.work_outline,
                  grouped: true,
                  account: widget.account,
                  resourceLabel: l10n.pipelineJobsTitle(widget.project.path, widget.id),
                  onSwitchAccount: endSessionFrom(context),
                  arrange: stageOrder,
                  sectionOf: (value) => valueText(value, 'stage', l10n.pipelineSourceOther),
                  cached: ({required bool fresh, required bool background}) => widget.api.cachedRecords(
                    ['projects', '${widget.project.id}', 'pipelines', '${widget.id}', 'jobs'],
                    query: {'include_retried': 'true', 'per_page': '100'},
                    fresh: fresh, background: background),
                  load: (next) => widget.api.records(
                    ['projects', '${widget.project.id}', 'pipelines', '${widget.id}', 'jobs'],
                    query: {'include_retried': 'true', 'per_page': '100'},
                    next: next,
                  ),
                  itemBuilder: (context, value) {
                    final jobId = requiredInt(value, 'id');
                    final status = valueText(value, 'status');
                    final duration = value['duration'] is num ? formatDuration((value['duration'] as num).round()) : '';
                    return Row(
                        children: [
                          Expanded(
                            child: SemanticButton(
                              label: jobCardLabel(value),
                              onTap: () => _openJob(jobId),
                              child: InkWell(
                                onTap: () => _openJob(jobId),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(valueText(value, 'name'), maxLines: 2, overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleSmall),
                                      const SizedBox(height: 5),
                                      Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                        StatusBadge(status),
                                        if (duration.isNotEmpty) MetaChip(duration, icon: Icons.timer_outlined),
                                        ?PersonChip.of(valueObject(value, 'user'), author: false),
                                      ]),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (status == 'manual')
                            IconButton(
                              key: ValueKey('job-action-play-$jobId'),
                              icon: Icon(Icons.play_circle_outline, color: Theme.of(context).colorScheme.primary),
                              tooltip: l10n.runManualJob,
                              onPressed: _busy ? null : () => _jobAction(jobId, 'play'),
                            )
                          else if (status == 'failed')
                            IconButton(
                              key: ValueKey('job-action-retry-$jobId'),
                              icon: const Icon(Icons.replay, color: Colors.orange),
                              tooltip: l10n.retryJob,
                              onPressed: _busy ? null : () => _jobAction(jobId, 'retry'),
                            )
                          else if (status == 'running' || status == 'pending')
                            IconButton(
                              key: ValueKey('job-action-cancel-$jobId'),
                              icon: const Icon(Icons.cancel_outlined, color: Colors.red),
                              tooltip: l10n.cancelJob,
                              onPressed: _busy ? null : () => _jobAction(jobId, 'cancel'),
                            ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right, size: 18),
                            tooltip: l10n.viewJobLog,
                            onPressed: () => _openJob(jobId),
                          ),
                          const SizedBox(width: 4),
                        ],
                    );
                  },
                ),
                PipelineTestsView(
                  key: _testsKey,
                  account: widget.account,
                  api: widget.api,
                  project: widget.project,
                  pipelineId: widget.id,
                  pipelineStatus: valueText(_data!, 'status'),
                  onOpenJob: _openJob,
                ),
              ],
            ),
          ),
      ]))),
      ),
    ),
  );
  }
}

class PipelineTestsView extends StatefulWidget {
  const PipelineTestsView({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.pipelineId,
    required this.pipelineStatus,
    required this.onOpenJob,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int pipelineId;
  final String pipelineStatus;
  final Future<void> Function(int jobId) onOpenJob;

  @override
  State<PipelineTestsView> createState() => PipelineTestsViewState();
}

class PipelineTestsViewState extends State<PipelineTestsView> with AutomaticKeepAliveClientMixin {
  static const int maxCasesBudget = 500;
  static const int maxOutputChars = 5000;

  int _generation = 0;
  int _casesGeneration = 0;
  bool _loadingSummary = false;
  bool _loadingCases = false;
  bool _loadingMore = false;
  TestReportSummary? _summary;
  ApiFailure? _summaryError;
  ApiFailure? _casesError;
  List<TestCase> _cases = [];
  Uri? _nextPage;
  String _filter = 'all';
  final Set<String> _expandedCases = {};

  @override
  bool get wantKeepAlive => true;

  bool get _isInProgress => const [
    'running',
    'pending',
    'preparing',
    'waiting_for_resource',
    'scheduled',
    'created',
  ].contains(widget.pipelineStatus.toLowerCase());

  @override
  void initState() {
    super.initState();
    unawaited(refresh(fresh: false));
  }

  @override
  void didUpdateWidget(covariant PipelineTestsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pipelineId != widget.pipelineId ||
        oldWidget.pipelineStatus != widget.pipelineStatus) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _generation++;
    _casesGeneration++;
    super.dispose();
  }

  Future<void> refresh({bool fresh = true}) async {
    final gen = ++_generation;
    setState(() {
      _loadingSummary = true;
      _summaryError = null;
      _casesError = null;
      _cases = [];
      _nextPage = null;
    });

    try {
      final api = widget.api;
      final path = [
        'projects', '${widget.project.id}', 'pipelines',
        '${widget.pipelineId}', 'test_report_summary',
      ];
      var read = await api.cachedRecord(
        path, fresh: fresh, maxAge: const Duration(seconds: 30),
      );
      if (!mounted || gen != _generation) return;
      if (read.superseded) {
        read = await api.cachedRecord(path, fresh: true);
      }
      if (read.dropped || read.superseded) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      final summary = TestReportSummary.fromJson(read.value);
      if (!mounted || gen != _generation) return;
      setState(() {
        _summary = summary;
        _loadingSummary = false;
        if (summary.failedCount > 0) {
          _filter = 'failed';
        } else if (summary.errorCount > 0) {
          _filter = 'error';
        } else {
          _filter = 'all';
        }
      });
      if (summary.totalCount > 0) {
        unawaited(_loadCases(gen));
      }
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _summaryError = safeFailure(e);
        _loadingSummary = false;
      });
    }
  }

  Future<void> _loadCases(int summaryGen) async {
    final caseGen = ++_casesGeneration;
    setState(() {
      _loadingCases = true;
      _casesError = null;
    });

    try {
      final page = await widget.api.pipelineTestReport(
        widget.project.id,
        widget.pipelineId,
        perPage: 30,
      );
      if (!mounted || summaryGen != _generation || caseGen != _casesGeneration) return;
      setState(() {
        _cases = page.testCases;
        _nextPage = page.next;
        _loadingCases = false;
      });
    } catch (e) {
      if (!mounted || summaryGen != _generation || caseGen != _casesGeneration) return;
      setState(() {
        _casesError = safeFailure(e);
        _loadingCases = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final next = _nextPage;
    if (next == null || _loadingMore || _loadingCases) return;
    if (_cases.length >= maxCasesBudget) return;
    final gen = _generation;
    final caseGen = _casesGeneration;
    setState(() {
      _loadingMore = true;
      _casesError = null;
    });

    try {
      final page = await widget.api.pipelineTestReport(
        widget.project.id,
        widget.pipelineId,
        next: next,
      );
      if (!mounted || gen != _generation || caseGen != _casesGeneration) return;
      final seen = _cases.map((c) => c.identity).toSet();
      final newCases = <TestCase>[];
      for (final c in page.testCases) {
        if (!seen.contains(c.identity)) newCases.add(c);
      }
      setState(() {
        _cases = [..._cases, ...newCases];
        _nextPage = page.next;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation || caseGen != _casesGeneration) return;
      setState(() {
        _casesError = safeFailure(e);
        _loadingMore = false;
      });
    }
  }

  String _filterLabel(String filter) => switch (filter) {
    'all' => l10n.filterAll,
    'failed' => l10n.statusFailed,
    'error' => l10n.statusError,
    'skipped' => l10n.statusSkipped,
    'success' => l10n.statusPassed,
    _ => filter,
  };

  String _truncateOutput(String text) {
    if (text.length <= maxOutputChars) return text;
    return l10n.truncatedJobOutput(text.substring(0, maxOutputChars));
  }

  Widget _buildSummaryCard(BuildContext context, TestReportSummary summary) {
    final theme = Theme.of(context);
    final workshop = WorkshopColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusBadge(switch (summary.status) {
                  TestReportStatus.failed => 'failed',
                  TestReportStatus.error => 'error',
                  TestReportStatus.suiteError => 'error',
                  TestReportStatus.skipped => 'skipped',
                  TestReportStatus.success => 'success',
                  _ => 'status_unknown',
                }),
                Text(l10n.testTotalCount(summary.totalCount), style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(l10n.testSuccessCount(summary.successCount), style: TextStyle(color: workshop.onSuccessContainer)),
                if (summary.failedCount > 0)
                  Text(l10n.testFailedCount(summary.failedCount), style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold)),
                if (summary.errorCount > 0)
                  Text(l10n.testErrorCount(summary.errorCount), style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold)),
                if (summary.skippedCount > 0)
                  Text(l10n.testSkippedCount(summary.skippedCount), style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                Text(l10n.testDurationSeconds(summary.totalTime.toStringAsFixed(2)), style: theme.textTheme.bodySmall),
              ],
            ),
            if (summary.hasSuiteError) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.testSuiteParseError(summary.suiteError ?? summary.testSuites.firstWhere((s) => s.hasSuiteError, orElse: () => TestSuiteSummary(name: '', totalTime: 0, totalCount: 0, successCount: 0, failedCount: 0, skippedCount: 0, errorCount: 0, suiteError: l10n.unknownSuiteError)).suiteError),
                        style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips(BuildContext context, TestReportSummary summary) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(l10n.testFilterAllCount(summary.totalCount)),
              selected: _filter == 'all',
              showCheckmark: false,
              onSelected: (_) => setState(() => _filter = 'all'),
            ),
          ),
          if (summary.failedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.testFilterFailedCount(summary.failedCount)),
                selected: _filter == 'failed',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'failed'),
              ),
            ),
          if (summary.errorCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.testFilterErrorCount(summary.errorCount)),
                selected: _filter == 'error',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'error'),
              ),
            ),
          if (summary.skippedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.testFilterSkippedCount(summary.skippedCount)),
                selected: _filter == 'skipped',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'skipped'),
              ),
            ),
          if (summary.successCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(l10n.testFilterSuccessCount(summary.successCount)),
                selected: _filter == 'success',
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = 'success'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTestCaseCard(BuildContext context, TestCase item) {
    final theme = Theme.of(context);
    final isExpanded = _expandedCases.contains(item.identity);
    final hasTraceOrOutput = (item.stackTrace != null && item.stackTrace!.isNotEmpty) ||
        (item.systemOutput != null && item.systemOutput!.isNotEmpty);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxTextWidth = constraints.maxWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusBadge(item.status),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.name,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (item.classname != null && item.classname!.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxTextWidth),
                        child: Text(
                          item.classname!,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: codeFontFamily,
                            fontFamilyFallback: ['Menlo', 'monospace'],
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (item.suiteName != null && item.suiteName!.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxTextWidth),
                        child: Text(
                          l10n.testSuiteName(item.suiteName),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (item.file != null && item.file!.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxTextWidth),
                        child: Text(
                          item.file!,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (item.executionTime != null)
                      Text(l10n.testCaseDurationSeconds(item.executionTime!.toStringAsFixed(3)), style: theme.textTheme.bodySmall),
                  ],
                ),
                if (item.jobId != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.terminal, size: 16),
                      label: Text(l10n.testJobId(item.jobId)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => widget.onOpenJob(item.jobId!),
                    ),
                  ),
                ],
                if (hasTraceOrOutput) ...[
                  const SizedBox(height: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setState(() {
                        if (isExpanded) {
                          _expandedCases.remove(item.identity);
                        } else {
                          _expandedCases.add(item.identity);
                        }
                      });
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(
                        children: [
                          TurnChevron(open: isExpanded, size: 20),
                          const SizedBox(width: 6),
                          Text(
                            l10n.errorTraceAndOutput,
                            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ExpandSection(expanded: isExpanded, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (item.stackTrace != null && item.stackTrace!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(l10n.errorStacktrace, style: theme.textTheme.labelSmall),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          _truncateOutput(item.stackTrace!),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            fontFamily: codeFontFamily,
                            fontFamilyFallback: ['Menlo', 'monospace'],
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                    if (item.systemOutput != null && item.systemOutput!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(l10n.systemOutput, style: theme.textTheme.labelSmall),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          _truncateOutput(item.systemOutput!),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            fontFamily: codeFontFamily,
                            fontFamilyFallback: ['Menlo', 'monospace'],
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ])),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final gutter = feedGutter(context);

    if (_loadingSummary && _summary == null) {
      return const ListSkeleton();
    }

    if (_summaryError != null) {
      if (_summaryError!.status == 404 || _summaryError!.kind == FailureKind.invisible) {
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(gutter, 24, gutter, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              if (_isInProgress)
                EmptyState(l10n.testsInProgress, detail: l10n.pipelineTestReportPending, icon: Icons.schedule)
              else
                EmptyState(
                  l10n.noTestReport,
                  detail: l10n.junitReportMissing,
                  icon: Icons.rule_folder_outlined,
                  action: TextButton.icon(
                    onPressed: () => endSessionFrom(context),
                    icon: const Icon(Icons.switch_account),
                    label: Text(l10n.switchAccount),
                  ),
                ),
            ],
          ),
        );
      }
      return FailureNotice(
        _summaryError!,
        account: widget.account,
        resourceLabel: l10n.pipelineTestReportTitle(widget.project.path, widget.pipelineId),
        onSwitchAccount: endSessionFrom(context),
        onRetry: refresh,
      );
    }

    final summary = _summary;
    if (summary == null || summary.isEmpty) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(gutter, 24, gutter, 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (_isInProgress)
              EmptyState(l10n.testsInProgress, detail: l10n.pipelineTestReportPending, icon: Icons.schedule)
            else
              EmptyState(l10n.noTestReport, detail: l10n.pipelineNoTestCases, icon: Icons.rule_folder_outlined),
          ],
        ),
      );
    }

    final filteredCases = _cases.where((c) => switch (_filter) {
      'failed' => c.isFailed,
      'error' => c.isError,
      'skipped' => c.isSkipped,
      'success' => c.isSuccess,
      _ => true,
    }).toList();

    final isPartial = summary.totalCount > _cases.length || _nextPage != null;

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          _buildSummaryCard(context, summary),
          const SizedBox(height: 12),
          _buildFilterChips(context, summary),
          const SizedBox(height: 12),
          if (isPartial)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.testCasesPartialLoaded(_cases.length, summary.totalCount),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_loadingCases && _cases.isEmpty)
            const ListSkeleton()
          else if (_cases.isEmpty && _casesError != null)
            const SizedBox.shrink()
          else if (filteredCases.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: EmptyState(l10n.noLoadedTestsForFilter(_filterLabel(_filter))),
            )
          else
            for (final c in filteredCases)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildTestCaseCard(context, c),
              ),
          if (_casesError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FailureNotice(
                _casesError!,
                account: widget.account,
                resourceLabel: l10n.testCasesPageTitle(widget.project.path),
                onSwitchAccount: endSessionFrom(context),
                onRetry: _cases.isEmpty ? () => _loadCases(_generation) : _loadMore,
              ),
            ),
          if (_loadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_nextPage != null)
            if (_cases.length >= maxCasesBudget)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  l10n.testPreviewLimitReached(maxCasesBudget),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextButton.icon(
                  icon: const Icon(Icons.expand_more),
                  label: Text(l10n.loadMoreTestCases),
                  onPressed: _loadMore,
                ),
              ),
        ],
      ),
    );
  }
}

// Storage, progress and sharing primitives are exported from artifact_storage.dart.

class JobLogPage extends StatefulWidget {
  const JobLogPage({super.key, required this.account, required this.api, required this.project, required this.id,
    this.generation = 0, this.sharer = const SystemArtifactSharer(), this.artifactDirectory = jobArtifactDirectory,
    this.openSink = openArtifactSink, this.promoteArtifact = promoteArtifactFile});
  final Account account;
  final GitLabApi api;
  final Project project;
  final int generation;
  final int id;
  final ArtifactSharer sharer;
  final Future<Directory> Function(Account account, int projectId, int jobId) artifactDirectory;
  final IOSink Function(File file) openSink;
  final Future<File> Function(File partial, File target) promoteArtifact;
  @override
  JobLogPageState createState() => JobLogPageState();
}
class JobLogPageState extends State<JobLogPage> with WidgetsBindingObserver {
  late final JobLogPage _routeOwner;
  late int _jobId;
  int _loadEpoch = 0;
  Json? _job;
  JobTrace _trace = JobTrace.empty;
  JobTrace _indexed = JobTrace.empty;
  BytesBuilder _rawBytes = BytesBuilder(copy: false);
  int _traceOffset = 0;

  /// The verified tail of this attempt's finished log, when one is shown. Its
  /// offsets are absolute; it may start after byte 0 (C2 §4.5).
  ReadCacheTerminalLog? _tail;

  /// Whether leading lines of the tail were also left out, to stay within the
  /// screen's line limit.
  bool _tailClipped = false;
  List<int> _sectionOrder = const <int>[];
  List<List<int>> _sectionChildren = const <List<int>>[];
  List<int> _sectionRoots = const <int>[];
  Set<int> _queryHits = const <int>{};
  final Map<String, bool> _sectionOpen = {};
  ApiFailure? _error;
  bool _loading = false, _busy = false, _confirming = false, _downloading = false, _auto = false, _follow = true;
  String _query = '';
  final _searchController = TextEditingController();
  List<_LogMatch> _matches = const <_LogMatch>[];
  int _currentMatch = 0;
  Timer? _timer;
  Duration? _timerInterval;
  StreamSubscription<RateBudgetSnapshot>? _rateBudgetSubscription;
  ValueListenable<TickerModeData>? _tickerMode;
  late RateLevel _rateLevel;
  final _scroll = ScrollController();
  final _chrome = ScrollChromeController();
  Duration get pollingInterval => switch (_rateLevel) {
    RateLevel.normal => const Duration(seconds: 10),
    RateLevel.low => const Duration(seconds: 30),
    RateLevel.critical => const Duration(seconds: 60),
  };
  @override
  void initState() {
    super.initState(); _routeOwner = widget; _jobId = widget.id;
    _rateLevel = widget.api.rateBudget.snapshot().level;
    _rateBudgetSubscription = widget.api.rateBudget.stream.listen((snapshot) {
      if (!mounted || snapshot.level == _rateLevel) return;
      // The auto-refresh chip names the cadence, so it rebuilds too.
      setState(() => _rateLevel = snapshot.level);
      _schedule();
    });
    WidgetsBinding.instance.addObserver(this); unawaited(_load());
  }
  void _updateTickerMode() {
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_tickerModeChanged);
      _tickerMode = mode;
      mode.addListener(_tickerModeChanged);
    }
    _tickerModeChanged();
  }
  void _tickerModeChanged() => _schedule();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateTickerMode();
    ModalRoute.isCurrentOf(context);
    _schedule();
  }
  @override
  void dispose() {
    _loadEpoch++; _timer?.cancel(); _scroll.dispose();
    unawaited(_rateBudgetSubscription?.cancel());
    _tickerMode?.removeListener(_tickerModeChanged);
    _searchController.dispose(); _chrome.dispose();
    WidgetsBinding.instance.removeObserver(this); super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) { _timer?.cancel(); }
    else { _schedule(); }
  }
  void _schedule() {
    if (!_auto || !mounted || _tickerMode?.value.enabled != true ||
        ModalRoute.isCurrentOf(context) != true ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _timer?.cancel();
      return;
    }
    // Dependency and ticker notifications can repeat after visibility resumes.
    // Keep the existing deadline unless the budget changed its cadence.
    if (_timer?.isActive == true && _timerInterval == pollingInterval) return;
    _timer?.cancel();
    _timerInterval = pollingInterval;
    _timer = Timer.periodic(pollingInterval, (_) {
      if (mounted && _tickerMode?.value.enabled == true && ModalRoute.isCurrentOf(context) == true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && !_loading && !_busy && !_confirming) {
        unawaited(_load());
      }
    });
  }
  Future<void> _load() async {
    if (_loading || !mounted) { return; }
    final epoch = ++_loadEpoch, jobId = _jobId;
    bool current() => mounted && epoch == _loadEpoch && jobId == _jobId;
    final follow = _follow && (!_scroll.hasClients || _scroll.position.extentAfter < 80);
    setState(() { _loading = true; _error = null; });
    try {
      final job = await widget.api.record(['projects', '${widget.project.id}', 'jobs', '$jobId']);
      if (!current()) { return; }
      // Metadata and trace have independent failure modes. Keep the controls
      // usable even when an expired or oversized trace cannot be displayed.
      setState(() {
        _job = job;
        if (!const ['running', 'pending', 'created', 'preparing', 'waiting_for_resource'].contains(job['status'])) {
          _auto = false; _timer?.cancel();
        }
      });
      // A finished job read from its start (or already shown as a tail) uses
      // the pinned terminal tail; a job seen running keeps the polled path.
      final terminal = const {'success', 'failed', 'canceled', 'skipped'}.contains(job['status']);
      final tail = terminal && (_tail != null || (_traceOffset == 0 && _rawBytes.isEmpty))
          ? await _terminalTail(jobId, current) : null;
      if (!current()) { return; }
      var changed = false;
      if (tail != null) {
        // A fresh builder: the tail never joins bytes of an earlier read or
        // attempt, and the next offset is the tail's absolute end.
        _rawBytes = BytesBuilder(copy: false)..add(tail.bytes);
        _traceOffset = tail.nextOffset;
        _tail = tail;
        _auto = false;
        _timer?.cancel();
        changed = true;
      } else {
        if (_tail != null) {
          // The tail no longer applies; restart the original path from byte 0.
          _tail = null;
          _rawBytes = BytesBuilder(copy: false);
          _traceOffset = 0;
        }
        final chunk = await widget.api.jobTraceChunk(widget.project.id, jobId, offset: _traceOffset);
        if (!current()) { return; }
        if (chunk.isEof) {
          _auto = false;
          _timer?.cancel();
        }
        changed = chunk.bytes.isNotEmpty || _rawBytes.isEmpty;
        if (chunk.bytes.isNotEmpty) {
          if (chunk.nextOffset != null && chunk.nextOffset! < _traceOffset) {
            _rawBytes = BytesBuilder(copy: false);
            _rawBytes.add(chunk.bytes);
            _traceOffset = chunk.nextOffset!;
          } else {
            _rawBytes.add(chunk.bytes);
            _traceOffset = chunk.nextOffset ?? _rawBytes.length;
          }
        }
      }
      if (changed) {
        var text = utf8.decode(_rawBytes.toBytes(), allowMalformed: true);
        // A 2 MiB tail can hold more lines than the screen parses; keep its
        // last lines. Display only: offsets and stored bytes are unchanged.
        _tailClipped = false;
        if (_tail != null) {
          final kept = _lastLines(text, GitLabApi.maxTextLines - 1);
          _tailClipped = kept.length != text.length;
          text = kept;
        }
        final parsed = JobTrace.parse(text);
        setState(() {
          _trace = parsed;
          if (_query.isNotEmpty) {
            _matches = _findMatches(_query);
            if (_matches.isEmpty) {
              _currentMatch = 0;
            } else if (_currentMatch >= _matches.length) {
              _currentMatch = _matches.length - 1;
            }
          }
        });
      }
      if (follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (current() && _scroll.hasClients) { _scroll.jumpTo(_scroll.position.maxScrollExtent); }
        });
      }
    } catch (e) {
      if (current()) { setState(() { _error = safeFailure(e); _auto = false; _timer?.cancel(); }); }
    } finally { if (current()) { setState(() => _loading = false); } }
  }

  /// The end of [text] holding at most [newlines] line breaks.
  static String _lastLines(String text, int newlines) {
    var seen = 0;
    for (var i = text.length - 1; i >= 0; i--) {
      if (text.codeUnitAt(i) != 0x0A) continue;
      if (++seen > newlines) return text.substring(i + 1);
    }
    return text;
  }

  /// The finished job's verified tail, from memory, the offline cache or one
  /// bounded range read. Null only when GitLab cannot serve it that way
  /// (`unsupported`); every other failure is the page's failure. A read that
  /// would start after the page went away is dropped.
  Future<ReadCacheTerminalLog?> _terminalTail(int jobId, bool Function() current) async {
    try {
      final read = await CachedRead.run(
        () => widget.api.cachedTerminalJobTrace(widget.project.id, jobId),
        mayStart: current,
      );
      if (read.dropped) throw const ApiFailure(FailureKind.cancelled);
      return read.value;
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.unsupported) return null;
      rethrow;
    }
  }
  Future<void> _openAi() async {
    final job = _job;
    if (job == null) { return; }
    await openAiChat(context, AiJobOrigin(project: widget.project, jobId: _jobId, jobName: valueText(job, 'name')));
  }
  Future<void> _action(String action) async {
    if (_busy || _confirming || _job == null) { return; }
    if (action == 'artifacts') {
      await _downloadArtifacts();
      return;
    }
    final jobId = _jobId;
    final label = action == 'retry' ? l10n.retryJob : action == 'play' ? l10n.startManualJob : l10n.cancelJob;
    // Confirmation prevents duplicate dialogs but is not a running operation.
    setState(() => _confirming = true);
    try {
      if (!await confirmAction(context, l10n.confirmActionQuestion(label), '${widget.project.path}\nJob #$jobId')) { return; }
      if (!mounted || jobId != _jobId) { return; }
      setState(() { _confirming = false; _busy = true; });
      final result = await widget.api.jobAction(widget.project.id, jobId, action);
      final newId = requiredInt(result, 'id');
      if (!mounted || jobId != _jobId) { return; }
      if (action != 'retry' && newId != jobId) { throw const ApiFailure(FailureKind.invalidResponse); }
      // Keep one route across job attempts, so the parent's navigation await
      // completes on real back. Discard stale trace results from older epochs.
      setState(() {
        _loadEpoch++; _loading = false; _error = null;
        _auto = false; _timer?.cancel(); _job = result;
        if (newId != _jobId || action == 'retry') {
          _jobId = newId; _trace = JobTrace.empty; _query = ''; _matches = const <_LogMatch>[];
          _currentMatch = 0; _searchController.clear(); _follow = true; _sectionOpen.clear();
          _rawBytes = BytesBuilder(copy: false);
          _traceOffset = 0;
          _tail = null;
          _tailClipped = false;
        }
      });
      await _load();
    } catch (e) { if (mounted) { showFailure(context, e); } }
    finally { if (mounted) { setState(() { _busy = false; _confirming = false; }); } }
  }
  bool get _ownerCurrent => mounted && !widget.api.isClosed &&
      widget.account.key == _routeOwner.account.key && identical(widget.api, _routeOwner.api) &&
      widget.project.id == _routeOwner.project.id && widget.id == _routeOwner.id &&
      widget.generation == _routeOwner.generation;
  /// The job's pipeline chip; a link when the job names a pipeline of this project.
  Widget? _pipelineChip(Json job) {
    final pipeline = valueObject(job, 'pipeline');
    final id = valueInt(pipeline, 'id');
    if (id <= 0) return null;
    final iid = valueInt(pipeline, 'iid');
    final label = 'Pipeline #${iid > 0 ? iid : id}';
    final projectId = valueInt(pipeline, 'project_id');
    if (projectId > 0 && projectId != widget.project.id) {
      return MetaChip(label, icon: Icons.rocket_launch_outlined);
    }
    return MetaChip(label, icon: Icons.rocket_launch_outlined, key: const ValueKey('job-pipeline-link'),
      semanticLabel: l10n.openLabeledItem(label), onTap: () {
        if (!_ownerCurrent) return;
        final owner = widget;
        unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PipelinePage(
          account: owner.account, api: owner.api, project: owner.project, id: id))));
      });
  }
  String _sectionKey(JobTraceSection section) => '${section.name}:${section.start}';
  void _ensureSectionIndex() {
    if (identical(_indexed, _trace)) return;
    final built = _indexSections(_trace);
    _indexed = _trace;
    _sectionOrder = built.order;
    _sectionChildren = built.children;
    _sectionRoots = built.roots;
  }
  bool _collapsed(int index) {
    final section = _trace.sections[index];
    final opened = _sectionOpen[_sectionKey(section)];
    if (opened != null) return !opened;
    if (_queryHits.contains(index)) return false;
    return section.collapsed;
  }
  void _toggleSection(int index) {
    final key = _sectionKey(_trace.sections[index]);
    setState(() => _sectionOpen[key] = _collapsed(index));
  }
  Set<int> _sectionsMatching(String query) {
    if (query.isEmpty) return const <int>{};
    final needle = query.toLowerCase();
    final sections = _trace.sections;
    final hits = <int>{};
    var next = 0;
    final active = <int>[];
    for (var line = 0; line < _trace.lines.length; line++) {
      while (active.isNotEmpty && sections[active.last].endLine <= line) {
        active.removeLast();
      }
      while (next < _sectionOrder.length && sections[_sectionOrder[next]].startLine <= line) {
        final index = _sectionOrder[next];
        if (sections[index].endLine > line) active.add(index);
        next++;
      }
      if (_trace.lines[line].text.toLowerCase().contains(needle)) hits.addAll(active);
    }
    return hits;
  }
  List<_LogMatch> _findMatches(String query) {
    if (query.isEmpty) return const <_LogMatch>[];
    final needle = query.toLowerCase();
    final matches = <_LogMatch>[];
    for (var l = 0; l < _trace.lines.length; l++) {
      final text = _trace.lines[l].text;
      final lower = text.toLowerCase();
      var start = 0;
      while (start < lower.length) {
        final idx = lower.indexOf(needle, start);
        if (idx < 0) break;
        matches.add(_LogMatch(lineIndex: l, start: idx, end: idx + needle.length));
        start = idx + needle.length;
      }
    }
    return matches;
  }
  void _prevMatch() {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatch = (_currentMatch - 1 + _matches.length) % _matches.length;
    });
    _scrollToMatch();
  }
  void _nextMatch() {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatch = (_currentMatch + 1) % _matches.length;
    });
    _scrollToMatch();
  }
  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _query = '';
      _matches = const <_LogMatch>[];
      _currentMatch = 0;
    });
  }
  void _scrollToMatch() {
    if (_matches.isEmpty || !_scroll.hasClients) return;
    final match = _matches[_currentMatch];
    var openedAny = false;
    for (var s = 0; s < _trace.sections.length; s++) {
      final sec = _trace.sections[s];
      if (sec.startLine <= match.lineIndex && sec.endLine > match.lineIndex) {
        final key = _sectionKey(sec);
        if (_sectionOpen[key] == false || (sec.collapsed && _sectionOpen[key] != true)) {
          _sectionOpen[key] = true;
          openedAny = true;
        }
      }
    }
    if (openedAny) {
      setState(() {});
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _matches.isEmpty) return;
      final rows = _visibleRows();
      var rowIndex = -1;
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].lineIndex == match.lineIndex) {
          rowIndex = i;
          break;
        }
      }
      if (rowIndex < 0) return;
      final position = _scroll.position;
      if (!position.hasContentDimensions) return;
      final span = position.maxScrollExtent;
      if (span <= 0 || !span.isFinite) return;
      final rowCount = rows.isEmpty ? 1 : rows.length;
      final avg = (span + position.viewportDimension) / rowCount;
      final target = (rowIndex * avg - position.viewportDimension * 0.2).clamp(0.0, span);
      if (target.isFinite) {
        _scroll.jumpTo(target);
      }
    });
  }
  List<InlineSpan> _buildHighlightSpans({
    required String text,
    required int? lineIndex,
    required TextStyle baseStyle,
  }) {
    if (_query.isEmpty || lineIndex == null) {
      return [TextSpan(text: text.isEmpty ? ' ' : text, style: baseStyle)];
    }
    final needle = _query.toLowerCase();
    final lower = text.toLowerCase();
    final spans = <InlineSpan>[];
    var cursor = 0;
    while (cursor < text.length) {
      final idx = lower.indexOf(needle, cursor);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
        break;
      }
      if (idx > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, idx), style: baseStyle));
      }
      final end = idx + needle.length;
      final isActive = _matches.isNotEmpty &&
          _currentMatch >= 0 &&
          _currentMatch < _matches.length &&
          _matches[_currentMatch].lineIndex == lineIndex &&
          _matches[_currentMatch].start == idx;
      spans.add(TextSpan(
        text: text.substring(idx, end),
        style: baseStyle.copyWith(
          backgroundColor: isActive ? const Color(0xFFFF9800) : const Color(0xFFFFE082),
          color: const Color(0xFF000000),
          fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
        ),
      ));
      cursor = end;
    }
    return spans;
  }
  List<_LogRow> _visibleRows() {
    _ensureSectionIndex();
    _queryHits = _sectionsMatching(_query);
    final rows = <_LogRow>[];
    final lines = _trace.lines;
    final sections = _trace.sections;
    final needle = _query.toLowerCase();
    void addLine(int line) {
      final traceLine = lines[line];
      if (needle.isEmpty || traceLine.text.toLowerCase().contains(needle)) {
        rows.add(_LogRow.line(traceLine, lineIndex: line));
      }
    }
    final stack = <_SectionWalk>[_SectionWalk(0, lines.length, _sectionRoots)];
    while (stack.isNotEmpty) {
      final frame = stack.last;
      if (frame.child >= frame.kids.length) {
        for (var line = frame.cursor; line < frame.to; line++) {
          addLine(line);
        }
        stack.removeLast();
        continue;
      }
      final index = frame.kids[frame.child];
      final section = sections[index];
      if (section.startLine < frame.cursor) {
        frame.child++;
        continue;
      }
      final end = section.endLine < frame.to ? section.endLine : frame.to;
      for (var line = frame.cursor; line < section.startLine && line < frame.to; line++) {
        addLine(line);
      }
      frame.cursor = end > frame.cursor ? end : frame.cursor;
      frame.child++;
      if (section.depth >= JobTrace.maxDepth) {
        for (var line = section.startLine; line < end; line++) {
          addLine(line);
        }
        continue;
      }
      rows.add(_LogRow.header(index));
      if (!_collapsed(index)) stack.add(_SectionWalk(section.startLine, end, _sectionChildren[index]));
    }
    return rows;
  }
  Widget _sectionHeader(int index) {
    final section = _trace.sections[index];
    final collapsed = _collapsed(index);
    final duration = section.durationSeconds;
    final title = duration == null ? section.label : l10n.labeledDurationSeconds(section.label, duration);
    return Semantics(
      button: true,
      expanded: !collapsed,
      label: title,
      excludeSemantics: true,
      onTap: () => _toggleSection(index),
      child: InkWell(
        onTap: () => _toggleSection(index),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: EdgeInsets.only(left: (section.depth > 4 ? 4 : section.depth) * 12.0),
            child: Row(children: [
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
              const SizedBox(width: 4),
              Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
      ),
    );
  }
  Future<void> _downloadArtifacts() async {
    final job = _job;
    if (job == null || _downloading) return;
    final info = valueObject(job, 'artifacts_file');
    final suggested = valueText(info, 'filename');
    if (suggested.isEmpty) return;
    final size = info['size'];
    final jobId = _jobId;
    final generation = widget.generation;
    final accountKey = widget.account.key;
    final api = widget.api;
    setState(() => _downloading = true);
    try {
      if (!mounted) return;
      await showModalBottomSheet<void>(context: context, isScrollControlled: true,
        builder: (context) => _ArtifactDownloadSheet(
          account: widget.account, api: api, projectId: widget.project.id, projectPath: widget.project.path,
          jobId: jobId, suggestedName: suggested, suggestedSize: size is int ? size : null,
          sharer: widget.sharer, artifactDirectory: widget.artifactDirectory, openSink: widget.openSink,
          promoteArtifact: widget.promoteArtifact,
          sessionCurrent: () => !api.isClosed && widget.generation == generation && widget.account.key == accountKey,
          webUri: widget.account.instance.projectWeb('${widget.project.path}/-/jobs/$jobId/artifacts/browse'),
        ));
    } catch (error) { if (mounted) showFailure(context, error); }
    finally { if (mounted) setState(() => _downloading = false); }
  }
  Widget _buildJobActionCard(String status) {
    if (status == 'manual') {
      return Card(
        key: ValueKey('job-banner-card-$_jobId'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.touch_app_outlined, color: Colors.blue, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.manualJobWaiting, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(l10n.manualJobTriggerRequired, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: ValueKey('job-banner-play-$_jobId'),
                onPressed: _busy || _confirming ? null : () => _action('play'),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(l10n.startJob),
              ),
            ],
          ),
        ),
      );
    }
    if (status == 'failed') {
      final failureReason = _job?['failure_reason'];
      return Card(
        key: ValueKey('job-banner-card-$_jobId'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.jobRunFailed, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      failureReason != null && '$failureReason'.isNotEmpty
                          ? l10n.jobFailureReason(failureReason)
                          : l10n.tapRetryToRestartJob,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                key: ValueKey('job-banner-retry-$_jobId'),
                onPressed: _busy || _confirming ? null : () => _action('retry'),
                icon: const Icon(Icons.replay, size: 18),
                label: Text(l10n.retryThisJob),
              ),
            ],
          ),
        ),
      );
    }
    if (status == 'running' || status == 'pending') {
      final isRunning = status == 'running';
      return Card(
        key: ValueKey('job-banner-card-$_jobId'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(isRunning ? Icons.play_circle_filled : Icons.hourglass_top, color: Colors.blue, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isRunning ? l10n.jobRunningEllipsis : l10n.jobWaitingSchedule,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(l10n.pipelineInProgressCancelable, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: ValueKey('job-banner-cancel-$_jobId'),
                onPressed: _busy || _confirming ? null : () => _action('cancel'),
                icon: const Icon(Icons.cancel_outlined, size: 18, color: Colors.red),
                label: Text(l10n.cancelThisJob, style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
  @override
  Widget build(BuildContext context) {
    final rows = _visibleRows();
    final noLog = _trace.lines.isEmpty && _trace.sections.isEmpty;
    // AI is offered only where the app was built with it (a registry above).
    final ai = _job != null && AiRunRegistry.maybeOf(context) != null;
    final failed = ai && valueText(_job!, 'status') == 'failed';
    final appBar = AppBar(primary: false, titleSpacing: 0, title: Text(_job == null ? 'Job #$_jobId' : valueText(_job!, 'name'), maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (failed) IconButton(key: const ValueKey('job-ai'), tooltip: l10n.aiDiscuss, onPressed: _openAi, icon: const Icon(Icons.auto_awesome)),
        ResourceShareButton(
        uri: widget.account.instance.projectWeb('${widget.project.path}/-/jobs/$_jobId'),
        ownerKey: (widget.account.key, widget.api, widget.project.id, _jobId, widget.generation),
        isCurrent: () => _ownerCurrent),
        IconButton(tooltip: l10n.reloadJobLog, onPressed: _loading || _busy || _confirming ? null : _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(tooltip: l10n.jobActions, enabled: !_busy && !_confirming && !_downloading && _job != null,
          onSelected: (value) => value == 'ai' ? _openAi() : _action(value), itemBuilder: (_) => [
          if (ai && !failed) PopupMenuItem(value: 'ai', child: Text(l10n.aiDiscuss)),
          PopupMenuItem(value: 'retry', child: Text(l10n.retryJob)),
          if (_job?['status'] == 'manual') PopupMenuItem(value: 'play', child: Text(l10n.startManualJob)),
          PopupMenuItem(value: 'cancel', child: Text(l10n.cancelJob)),
          if (valueObject(_job ?? {}, 'artifacts_file')['filename'] != null)
            PopupMenuItem(value: 'artifacts', child: Text(l10n.downloadArtifacts)),
        ]),
      ]);
    // The log owns the screen while reading: title, status and the action
    // banner slide away on scroll; the search row stays.
    return Scaffold(body: NotificationListener<ScrollNotification>(onNotification: _chrome.handle, child: StatusBarInset(
      child: gestureSafe(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CollapsingChrome(visible: _chrome, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          appBar,
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Wrap(
            spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (_job != null) StatusBadge(valueText(_job!, 'status')),
              Text(isolated('#$_jobId'), style: Theme.of(context).textTheme.bodySmall),
              if (_job != null) ...[
                ?_pipelineChip(_job!),
                if (valueText(_job!, 'stage').isNotEmpty) MetaChip(valueText(_job!, 'stage'), icon: Icons.layers_outlined),
                if (valueText(_job!, 'ref').isNotEmpty) MetaChip(valueText(_job!, 'ref'), icon: Icons.alt_route, mono: true),
              ],
              FilterChip(label: Text(switch (_rateLevel) {
                RateLevel.normal => l10n.refreshEveryTenSeconds,
                RateLevel.low => l10n.refreshEveryThirtySeconds,
                RateLevel.critical => l10n.refreshEveryMinute,
              }), selected: _auto, onSelected: (value) {
                setState(() => _auto = value); _schedule();
              }),
              FilterChip(label: Text(l10n.followLogTail), selected: _follow, onSelected: (value) => setState(() => _follow = value)),
            ])),
          if (_job != null) _buildJobActionCard(valueText(_job!, 'status')),
        ])),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('job-log-search-$_jobId'),
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: l10n.searchLoadedLog,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            tooltip: l10n.clearSearch,
                            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                            onPressed: _clearSearch,
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _query = value;
                      _matches = _findMatches(value);
                      _currentMatch = 0;
                      if (value.isNotEmpty) _follow = false;
                    });
                    if (_matches.isNotEmpty) {
                      _scrollToMatch();
                    }
                  },
                ),
              ),
              if (_query.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  _matches.isNotEmpty ? '${_currentMatch + 1}/${_matches.length}' : '0/0',
                  semanticsLabel: _matches.isNotEmpty
                      ? l10n.logMatchPosition(_currentMatch + 1, _matches.length)
                      : l10n.noLogMatches,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up),
                  tooltip: l10n.previousLogMatch,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: _matches.isNotEmpty
                      ? () {
                          setState(() => _follow = false);
                          _prevMatch();
                        }
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
                  tooltip: l10n.nextLogMatch,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: _matches.isNotEmpty
                      ? () {
                          setState(() => _follow = false);
                          _nextMatch();
                        }
                      : null,
                ),
              ],
            ],
          ),
        ),
        if ((_tail?.truncated ?? false) || _tailClipped) Padding(
          key: const ValueKey('job-log-truncated'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            Icon(Icons.vertical_align_top, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(l10n.readCacheLogTruncated, style: Theme.of(context).textTheme.bodySmall)),
          ]),
        ),
        if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) FailureNotice(_error!, onRetry: _busy || _confirming ? null : _load,
          account: widget.account, resourceLabel: '${widget.project.path} · Job #$_jobId',
          onSwitchAccount: endSessionFrom(context)),
        Expanded(child: noLog && !_loading && _error == null
          ? SingleChildScrollView(child: EmptyState(l10n.noLogYet,
              detail: _job?['status'] == 'manual' ? l10n.jobNotStartedMenuHint : l10n.jobLogAppearsAfterStart,
              icon: Icons.terminal))
          : Directionality(textDirection: TextDirection.ltr, child: SelectionArea(child: ListView.builder(controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: rows.length, itemBuilder: (context, index) {
                final row = rows[index];
                final section = row.section;
                if (section != null) return _sectionHeader(section);
                final traceLine = row.line;
                final text = row.text ?? '';
                final baseStyle = TextStyle(
                  fontFamily: codeFontFamily,
                  fontFamilyFallback: const ['Menlo', 'monospace'],
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurface,
                );
                Widget lineWidget;
                if (_query.isEmpty || text.isEmpty) {
                  final span = traceLine?.toInlineSpan(
                    brightness: Theme.of(context).brightness,
                    baseStyle: baseStyle,
                  ) ?? TextSpan(text: text.isEmpty ? ' ' : text, style: baseStyle);
                  lineWidget = Text.rich(span);
                } else {
                  final spans = _buildHighlightSpans(
                    text: text,
                    lineIndex: row.lineIndex,
                    baseStyle: baseStyle,
                  );
                  lineWidget = Text.rich(TextSpan(style: baseStyle, children: spans));
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: lineWidget,
                );
              },
            )))),
      ])))));
  }
}

final class _LogRow {
  const _LogRow.header(this.section) : text = null, line = null, lineIndex = null;
  _LogRow.line(this.line, {this.lineIndex}) : section = null, text = line?.text;
  final int? section;
  final String? text;
  final JobTraceLine? line;
  final int? lineIndex;
}

final class _LogMatch {
  const _LogMatch({
    required this.lineIndex,
    required this.start,
    required this.end,
  });
  final int lineIndex;
  final int start;
  final int end;
}

final class _SectionWalk {
  _SectionWalk(this.cursor, this.to, this.kids);
  int cursor;
  final int to;
  final List<int> kids;
  int child = 0;
}

final class _SectionIndex {
  const _SectionIndex(this.order, this.children, this.roots);
  final List<int> order;
  final List<List<int>> children;
  final List<int> roots;
}

_SectionIndex _indexSections(JobTrace trace) {
  final sections = trace.sections;
  final order = List<int>.generate(sections.length, (index) => index)..sort((a, b) {
    final start = sections[a].startLine.compareTo(sections[b].startLine);
    if (start != 0) return start;
    return sections[a].depth.compareTo(sections[b].depth);
  });
  final children = List<List<int>>.generate(sections.length, (_) => <int>[]);
  final roots = <int>[];
  final stack = <int>[];
  for (final index in order) {
    final section = sections[index];
    while (stack.isNotEmpty &&
        (sections[stack.last].endLine <= section.startLine || sections[stack.last].depth >= section.depth)) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(index);
    } else {
      children[stack.last].add(index);
    }
    stack.add(index);
  }
  return _SectionIndex(order, children, roots);
}

class _ArtifactDownloadSheet extends StatefulWidget {
  const _ArtifactDownloadSheet({
    required this.account, required this.api, required this.projectId, required this.projectPath,
    required this.jobId, required this.suggestedName, required this.suggestedSize,
    required this.sharer, required this.artifactDirectory, required this.openSink,
    required this.promoteArtifact, required this.sessionCurrent, required this.webUri,
  });
  final Account account;
  final GitLabApi api;
  final int projectId;
  final String projectPath;
  final int jobId;
  final String suggestedName;
  final int? suggestedSize;
  final ArtifactSharer sharer;
  final Future<Directory> Function(Account account, int projectId, int jobId) artifactDirectory;
  final IOSink Function(File file) openSink;
  final Future<File> Function(File partial, File target) promoteArtifact;
  final bool Function() sessionCurrent;
  final Uri webUri;
  @override
  State<_ArtifactDownloadSheet> createState() => _ArtifactDownloadSheetState();
}

class _ArtifactDownloadSheetState extends State<_ArtifactDownloadSheet> {
  Completer<void> _abort = Completer<void>();
  late final ArtifactProgress _progress;
  int _attempt = 0;
  bool _disposed = false, _done = false, _popWhenCancelled = false, _sharing = false;
  Directory? _attemptDirectory;
  File? _partial;
  String? _savedName, _savedPath;
  int _savedBytes = 0;
  ApiFailure? _error;
  @override
  void initState() {
    super.initState();
    _progress = ArtifactProgress(initial: (0, widget.suggestedSize));
    unawaited(_start());
  }
  @override
  void dispose() {
    _disposed = true;
    if (!_abort.isCompleted) _abort.complete();
    final directory = _attemptDirectory;
    final partial = _partial;
    _progress.dispose();
    unawaited(_deleteAttemptFiles(directory, partial));
    super.dispose();
  }
  Future<void> _start() async {
    final attempt = ++_attempt;
    final abort = Completer<void>();
    _abort = abort;
    IOSink? ownedSink;
    Directory? ownedDirectory;
    File? ownedPartial;
    Object? sinkFailure;
    // A closed client or a changed account/generation must not publish the archive.
    bool current() => !_disposed && mounted && attempt == _attempt && identical(_abort, abort) && !abort.isCompleted
        && widget.sessionCurrent();
    Future<void> cleanup() async {
      final open = ownedSink;
      ownedSink = null;
      if (open != null) {
        try {
          await open.close();
        } on Object catch (error) {
          if (error is! StateError && error is! FileSystemException) rethrow;
        }
      }
      await _deleteAttemptFiles(ownedDirectory, ownedPartial);
      if (identical(_attemptDirectory, ownedDirectory)) _attemptDirectory = null;
      if (identical(_partial, ownedPartial)) _partial = null;
      ownedDirectory = null;
      ownedPartial = null;
    }
    try {
      final directory = await widget.artifactDirectory(widget.account, widget.projectId, widget.jobId);
      ownedDirectory = directory;
      _attemptDirectory = directory;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      final partial = File('${directory.path}/$artifactPartialName');
      ownedPartial = partial;
      _partial = partial;
      final sink = widget.openSink(partial);
      ownedSink = sink;
      unawaited(sink.done.then<void>((_) {}, onError: (Object error, StackTrace _) {
        sinkFailure ??= error;
        if (!abort.isCompleted) abort.complete();
      }));
      final result = await widget.api.downloadJobArtifacts(widget.projectId, widget.jobId,
        sink: sink, cancel: abort.future, onProgress: (received, total) {
          if (_disposed || attempt != _attempt) return;
          _progress.report(received, total);
        });
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      await sink.flush();
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      await sink.close();
      ownedSink = null;
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      final name = _downloadFileName(result.fileName, widget.jobId);
      final target = File('${directory.path}/$name');
      if (sinkFailure != null) throw sinkFailure!;
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
      final saved = await widget.promoteArtifact(partial, target);
      ownedPartial = null;
      _partial = null;
      if (sinkFailure != null || !current()) {
        if (saved.existsSync()) await saved.delete();
        throw sinkFailure ?? const ApiFailure(FailureKind.cancelled);
      }
      _progress.report(result.bytesWritten, _progress.value.value.$2, completed: true);
      if (!mounted || attempt != _attempt) {
        await _deleteAttemptFiles(directory, null);
        if (identical(_attemptDirectory, directory)) _attemptDirectory = null;
        return;
      }
      setState(() {
        _done = true; _error = null; _savedName = name; _savedBytes = result.bytesWritten; _savedPath = target.path;
      });
    } catch (error) {
      await cleanup();
      if (_disposed || !mounted || attempt != _attempt) return;
      final cause = sinkFailure ?? error;
      final failure = cause is FileSystemException ? ApiFailure.artifactStorage : safeFailure(cause);
      if (sinkFailure == null && failure.kind == FailureKind.cancelled) {
        if (_popWhenCancelled) Navigator.pop(context);
        return;
      }
      setState(() => _error = failure);
    }
  }
  Future<void> _retry() async {
    if (!_abort.isCompleted) _abort.complete();
    if (!mounted || _disposed) return;
    setState(() { _error = null; _done = false; _savedName = null; _savedPath = null; _savedBytes = 0; });
    _progress.report(0, widget.suggestedSize, completed: true);
    await _start();
  }
  void _cancel() {
    _popWhenCancelled = true;
    if (!_abort.isCompleted) _abort.complete();
  }
  Future<void> _share(BuildContext buttonContext) async {
    final path = _savedPath;
    if (path == null || _sharing) return;
    setState(() => _sharing = true);
    final box = buttonContext.findRenderObject() as RenderBox?;
    final Rect? origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      await shareDownloadedArtifact(widget.sharer, path, sharePositionOrigin: origin);
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    return SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.suggestedName, style: Theme.of(context).textTheme.titleMedium),
        if (widget.suggestedSize != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(formatByteCount(widget.suggestedSize!), style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 16),
        if (_error != null) FailureNotice(_error!, onRetry: () { unawaited(_retry()); }, account: widget.account,
          resourceLabel: l10n.jobArtifactsTitle(widget.projectPath, widget.jobId), onSwitchAccount: endSessionFrom(context)),
        if (_done) ...[
          Text(l10n.artifactDownloadedSummary(_savedName ?? widget.suggestedName, formatByteCount(_savedBytes))),
          const SizedBox(height: 12),
          Builder(builder: (buttonContext) => FilledButton(
            onPressed: _sharing ? null : () => unawaited(_share(buttonContext)),
            child: Text(l10n.openOrShare),
          )),
          TextButton(onPressed: () => unawaited(openExternal(context, widget.webUri)), child: Text(l10n.openInGitlab)),
        ],
        if (_error == null && !_done) ...[
          ValueListenableBuilder<(int, int?)>(
            valueListenable: _progress.value,
            builder: (context, value, _) {
              final received = value.$1;
              final total = value.$2;
              final double? progress = total == null || total <= 0 ? null : (received / total).clamp(0.0, 1.0).toDouble();
              final bytes = total == null ? formatByteCount(received) : '${formatByteCount(received)} / ${formatByteCount(total)}';
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Semantics(
                  label: l10n.artifactDownloadProgress,
                  value: progress != null ? '${(progress * 100).toInt()}%' : l10n.downloading,
                  child: LinearProgressIndicator(key: const Key('artifact-progress'), minHeight: 4, value: progress),
                ),
                const SizedBox(height: 8),
                Text(bytes, style: Theme.of(context).textTheme.bodySmall),
              ]);
            },
          ),
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _cancel, child: Text(l10n.cancelAction))),
        ],
      ],
    )));
  }
}

Future<void> _deleteAttemptFiles(Directory? directory, File? partial) =>
    deleteAttemptFiles(directory, partial);

String _downloadFileName(String name, int job) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty || base == '.' || base == '..' || base == '.partial' || base == artifactPartialName ||
      base.contains('\u0000')) {
    return 'artifacts-$job.zip';
  }
  return base;
}

typedef JobPage = JobLogPage;
