import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/registry_models.dart';
import '../../shared/artifact_storage.dart';
import '../../shared/package_download.dart';
import '../../shared/resource_share.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'records_feed.dart';

const _maintainerAccess = 40;

final class _RequestScope {
  const _RequestScope(
    this.accountKey,
    this.api,
    this.projectId,
    this.generation,
  );
  final String accountKey;
  final GitLabApi api;
  final int projectId, generation;
}

Future<int> _effectiveAccess(
  Account account,
  GitLabApi api,
  Project project,
) async {
  try {
    final member = await api.record([
      'projects',
      '${project.id}',
      'members',
      'all',
      '${account.user.id}',
    ]);
    return valueInt(member, 'access_level');
  } on ApiFailure catch (failure) {
    if (failure.status == 404) return 0;
    rethrow;
  }
}

Future<List<Json>> _allRecords(
  GitLabApi api,
  List<String> path, {
  Map<String, String> query = const {},
  int maximumPages = 40,
}) async {
  final result = <Json>[];
  final cursors = <String>{};
  Uri? next;
  for (var page = 0; page < maximumPages; page++) {
    final response = await api.records(path, query: query, next: next);
    result.addAll(response.items);
    next = response.next;
    if (next == null) return result;
    if (!cursors.add(next.toString())) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
  throw const ApiFailure(
    FailureKind.unsupported,
    detail: '項目數超出安全回讀上限，請縮小範圍後重試。',
  );
}

/// Project package, Terraform module, and container registries.
class RegistriesPage extends StatelessWidget {
  const RegistriesPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.initialIndex = 0,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final int initialIndex;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: initialIndex.clamp(0, 2),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('套件與映像 Registry'),
        bottom: const TabBar(
          isScrollable: true,
          tabs: [
            Tab(text: '套件'),
            Tab(text: 'Container'),
            Tab(text: 'Terraform'),
          ],
        ),
      ),
      body: gestureSafe(
        TabBarView(
          children: [
            _PackagesTab(account: account, api: api, project: project),
            _ContainerRepositoriesTab(
              account: account,
              api: api,
              project: project,
            ),
            _PackagesTab(
              account: account,
              api: api,
              project: project,
              packageType: 'terraform_module',
            ),
          ],
        ),
      ),
    ),
  );
}

class _PackagesTab extends StatefulWidget {
  const _PackagesTab({
    required this.account,
    required this.api,
    required this.project,
    this.packageType,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final String? packageType;
  @override
  State<_PackagesTab> createState() => _PackagesTabState();
}

class _PackagesTabState extends State<_PackagesTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _search = TextEditingController();
  int _ownerGeneration = 0;
  String _appliedSearch = '';
  String _order = 'created_at';
  String _sort = 'desc';

  String get _identity => [
    widget.account.key,
    widget.project.id,
    _ownerGeneration,
    widget.packageType ?? 'all',
    _appliedSearch,
    _order,
    _sort,
  ].join('/');

  void _applySearch() {
    final value = _search.text.trim();
    if (value != _appliedSearch) setState(() => _appliedSearch = value);
  }

  @override
  void didUpdateWidget(covariant _PackagesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.packageType != widget.packageType) {
      _ownerGeneration++;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RecordsFeed(
    key: _feed,
    identity: _identity,
    storageId:
        'registry/${widget.account.key}/${widget.project.id}/packages/${widget.packageType ?? 'all'}/$_ownerGeneration',
    account: widget.account,
    resourceLabel:
        '${widget.project.path} · ${widget.packageType == null ? '套件 Registry' : 'Terraform Module Registry'}',
    onSwitchAccount: endSessionFrom(context),
    empty: widget.packageType == null ? '尚無套件' : '尚無 Terraform Module',
    emptyDetail: widget.packageType == null
        ? '發佈至 GitLab Package Registry 後會出現在這裡。'
        : 'Terraform Module 會以 terraform_module 套件類型列出。',
    filteredEmpty: '目前條件沒有符合的套件',
    emptyIcon: widget.packageType == null
        ? Icons.inventory_2_outlined
        : Icons.account_tree_outlined,
    grouped: true,
    load: (next) => widget.api.records(
      ['projects', '${widget.project.id}', 'packages'],
      query: {
        'order_by': _order,
        'sort': _sort,
        'include_versionless': 'true',
        if (_appliedSearch.isNotEmpty) 'package_name': _appliedSearch,
        if (widget.packageType != null) 'package_type': widget.packageType!,
      },
      next: next,
    ),
    leading: (_, _) => _RegistryToolbar(
      controller: _search,
      hint: widget.packageType == null ? '搜尋套件名稱' : '搜尋 Module 名稱',
      onSubmitted: (_) => _applySearch(),
      onSearch: _applySearch,
      order: _order,
      sort: _sort,
      orders: const {
        'created_at': '建立時間',
        'name': '名稱',
        'version': '版本',
        'type': '類型',
      },
      onOrder: (value) => setState(() => _order = value),
      onSort: (value) => setState(() => _sort = value),
    ),
    itemBuilder: (context, value) {
      late final RegistryPackage package;
      try {
        package = RegistryPackage.fromJson(value);
      } on FormatException {
        return const ListTile(
          leading: Icon(Icons.warning_amber_outlined),
          title: Text('無法解析套件資料'),
        );
      }
      final when = relativeDate(package.createdAt);
      return ListTile(
        minTileHeight: 68,
        leading: Icon(
          package.type == 'terraform_module'
              ? Icons.account_tree_outlined
              : Icons.inventory_2_outlined,
        ),
        title: Text(package.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            packageTypeLabel(package.type),
            package.version.isEmpty ? '無版本' : package.version,
            if (package.status.isNotEmpty && package.status != 'default')
              package.status,
            if (when.isNotEmpty) when,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => PackageDetailPage(
                account: widget.account,
                api: widget.api,
                project: widget.project,
                packageId: package.id,
              ),
            ),
          );
          if (changed == true && mounted) {
            await _feed.currentState?.reconcileLoadedWindow();
          }
        },
      );
    },
  );
}

class _RegistryToolbar extends StatelessWidget {
  const _RegistryToolbar({
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    required this.onSearch,
    required this.order,
    required this.sort,
    required this.orders,
    required this.onOrder,
    required this.onSort,
    this.detail,
  });
  final TextEditingController controller;
  final String hint, order, sort;
  final ValueChanged<String> onSubmitted, onOrder, onSort;
  final VoidCallback onSearch;
  final Map<String, String> orders;
  final String? detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchBar(
          controller: controller,
          hintText: hint,
          leading: const Icon(Icons.search),
          trailing: [
            IconButton(
              tooltip: '搜尋',
              onPressed: onSearch,
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
          onSubmitted: onSubmitted,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: order,
                decoration: const InputDecoration(
                  labelText: '排序欄位',
                  isDense: true,
                ),
                items: [
                  for (final entry in orders.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) onOrder(value);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: sort,
                decoration: const InputDecoration(
                  labelText: '方向',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'desc', child: Text('新到舊／降冪')),
                  DropdownMenuItem(value: 'asc', child: Text('舊到新／升冪')),
                ],
                onChanged: (value) {
                  if (value != null) onSort(value);
                },
              ),
            ),
          ],
        ),
        if (detail != null) ...[
          const SizedBox(height: 8),
          Text(
            detail!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}

class PackageDetailPage extends StatefulWidget {
  const PackageDetailPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.packageId,
    this.isCurrent,
    this.ownerChanges,
    this.packageDownloader,
    this.sharer = const SystemArtifactSharer(),
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int packageId;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final PackageDownloader? packageDownloader;
  final ArtifactSharer sharer;
  @override
  State<PackageDetailPage> createState() => _PackageDetailPageState();
}

class _PackageDetailPageState extends State<PackageDetailPage> {
  final _files = GlobalKey<RecordsFeedState>();
  RegistryPackage? _package;
  ApiFailure? _error;
  bool _busy = false;
  int _generation = 0;
  int _detailEpoch = 0;
  SessionController? _session;
  int? _sessionGeneration;

  Listenable? get _effectiveOwnerChanges =>
      widget.isCurrent != null ? widget.ownerChanges : _session;

  bool _downloadOwnerCurrent() {
    final explicit = widget.isCurrent;
    if (explicit != null) {
      return !widget.api.isClosed && explicit();
    }
    final session = _session;
    return !widget.api.isClosed &&
        session != null &&
        session.active?.key == widget.account.key &&
        identical(session.api, widget.api) &&
        session.generation == _sessionGeneration;
  }

  void _bindOwner() {
    if (widget.isCurrent != null) return;
    SessionController? candidate;
    try {
      candidate = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(sessionProvider);
    } on StateError {
      candidate = null;
    }
    if (!identical(_session, candidate)) {
      _session?.removeListener(_ownerChanged);
      _session = candidate;
      candidate?.addListener(_ownerChanged);
    }
    _sessionGeneration = candidate?.generation;
  }

  void _listenToExplicitOwner(Listenable? owner) {
    owner?.removeListener(_ownerChanged);
    owner?.addListener(_ownerChanged);
  }

  void _ownerChanged() {
    if (_downloadOwnerCurrent()) return;
    _generation++;
    _detailEpoch++;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _package = null;
      _error = const ApiFailure(FailureKind.cancelled);
    });
  }

  _RequestScope get _scope => _RequestScope(
    widget.account.key,
    widget.api,
    widget.project.id,
    _generation,
  );
  bool _current(_RequestScope scope) =>
      mounted &&
      scope.accountKey == widget.account.key &&
      identical(scope.api, widget.api) &&
      scope.projectId == widget.project.id &&
      scope.generation == _generation;

  List<String> get _path => [
    'projects',
    '${widget.project.id}',
    'packages',
    '${widget.packageId}',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.isCurrent != null) {
      _listenToExplicitOwner(widget.ownerChanges);
    }
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindOwner();
  }

  @override
  void didUpdateWidget(covariant PackageDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.packageId != widget.packageId) {
      _generation++;
      _package = null;
      _error = null;
      _busy = false;
      _detailEpoch++;
      _bindOwner();
      unawaited(_load());
    }
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges) ||
        (oldWidget.isCurrent == null) != (widget.isCurrent == null)) {
      if (oldWidget.isCurrent != null) {
        oldWidget.ownerChanges?.removeListener(_ownerChanged);
      }
      if (widget.isCurrent != null) {
        _session?.removeListener(_ownerChanged);
        _session = null;
        _sessionGeneration = null;
        _listenToExplicitOwner(widget.ownerChanges);
      } else {
        _bindOwner();
      }
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_ownerChanged);
    if (widget.isCurrent != null) {
      widget.ownerChanges?.removeListener(_ownerChanged);
    }
    _generation++;
    _detailEpoch++;
    super.dispose();
  }

  Future<void> _load() async {
    final scope = _scope;
    final epoch = ++_detailEpoch;
    if (mounted) setState(() => _error = null);
    try {
      final value = await scope.api.record(_path);
      final package = RegistryPackage.fromJson(value);
      if (_current(scope) && epoch == _detailEpoch) {
        setState(() => _package = package);
      }
    } catch (error) {
      if (_current(scope) && epoch == _detailEpoch) {
        setState(() => _error = safeFailure(error));
      }
    }
  }

  Future<void> _downloadFile(
    RegistryPackage package,
    RegistryPackageFile file,
  ) async {
    final blocked = packageFileDownloadBlockReason(package, file);
    if (blocked != null) {
      showFailure(
        context,
        ApiFailure(
          file.size > packageDownloadMaximumBytes
              ? FailureKind.tooLarge
              : FailureKind.unsupported,
          title: '無法下載套件檔案',
          detail: blocked,
        ),
      );
      return;
    }
    if (!_downloadOwnerCurrent()) {
      showFailure(
        context,
        const ApiFailure(
          FailureKind.cancelled,
          title: '工作階段已變更',
          detail: '請用目前帳號重新開啟這個套件後再下載。',
        ),
      );
      return;
    }
    final scope = _scope;
    final epoch = _detailEpoch;
    bool current() =>
        _current(scope) &&
        epoch == _detailEpoch &&
        _downloadOwnerCurrent() &&
        _package?.id == package.id &&
        _package?.name == package.name &&
        _package?.version == package.version &&
        _package?.type == package.type;
    await showPackageDownloadSheet(
      context,
      account: widget.account,
      api: widget.api,
      project: widget.project,
      package: package,
      file: file,
      isCurrent: current,
      ownerChanges: _effectiveOwnerChanges,
      downloader: widget.packageDownloader,
      sharer: widget.sharer,
    );
  }

  Future<void> _copyFileSha(RegistryPackageFile file) async {
    final scope = _scope;
    final epoch = _detailEpoch;
    final canonical = RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256);
    bool current() =>
        _current(scope) &&
        epoch == _detailEpoch &&
        _downloadOwnerCurrent() &&
        _package?.id == widget.packageId;
    if (!canonical || !current()) {
      if (mounted) {
        showFailure(
          context,
          const ApiFailure(
            FailureKind.cancelled,
            title: '工作階段已變更',
            detail: '請用目前帳號重新開啟這個套件後再複製。',
          ),
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: file.sha256));
    if (!mounted || !current()) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已複製完整 SHA-256')));
  }

  Future<void> _deletePackage() async {
    if (_busy) return;
    final scope = _scope;
    try {
      final fresh = RegistryPackage.fromJson(await scope.api.record(_path));
      if (!_current(scope)) return;
      if (!fresh.canDelete || widget.project.archived == true) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      if (!mounted) return;
      if (!await confirmAction(
            context,
            '刪除套件？',
            '將刪除 ${fresh.identity} 的所有檔案。若實例啟用轉送，請先確認沒有同名外部套件。',
            requiredText: fresh.identity,
          ) ||
          !_current(scope)) {
        return;
      }
      setState(() => _busy = true);
      await scope.api.removeRecord(_path);
      if (!_current(scope)) return;
      try {
        await scope.api.record(_path);
        throw const ApiFailure(FailureKind.writeUncertain);
      } on ApiFailure catch (failure) {
        if (failure.status != 404) rethrow;
      }
      if (_current(scope) && mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (_current(scope) && mounted) showFailure(context, error);
    } finally {
      if (_current(scope)) setState(() => _busy = false);
    }
  }

  Future<void> _deleteFile(RegistryPackageFile file) async {
    if (_busy) return;
    final scope = _scope;
    try {
      final freshPackage = RegistryPackage.fromJson(
        await scope.api.record(_path),
      );
      if (!_current(scope)) return;
      if (!freshPackage.canDelete || widget.project.archived == true) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      final filesPath = [..._path, 'package_files'];
      final freshFiles = await _allRecords(scope.api, filesPath);
      if (!_current(scope)) return;
      final exists = freshFiles.any(
        (item) =>
            valueInt(item, 'id') == file.id &&
            valueText(item, 'file_name') == file.name,
      );
      if (!exists) {
        throw const ApiFailure(FailureKind.conflict);
      }
      if (!mounted) return;
      if (!await confirmAction(
            context,
            '刪除套件檔案？',
            '刪除單一檔案可能使套件無法安裝。此操作只刪除 ${file.name}。',
            requiredText: file.name,
          ) ||
          !_current(scope)) {
        return;
      }
      setState(() => _busy = true);
      await scope.api.removeRecord([...filesPath, '${file.id}']);
      if (!_current(scope)) return;
      final after = await _allRecords(scope.api, filesPath);
      if (!_current(scope)) return;
      if (after.any((item) => valueInt(item, 'id') == file.id)) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      await _files.currentState?.reconcileLoadedWindow();
      if (_current(scope) && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('套件檔案已刪除並完成回讀。')));
      }
    } catch (error) {
      if (_current(scope) && mounted) showFailure(context, error);
    } finally {
      if (_current(scope)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final package = _package;
    final scope = _scope;
    return Scaffold(
      appBar: AppBar(
        title: Text(package?.name ?? '套件詳情', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (package != null)
            ResourceShareButton(uri: widget.account.instance.projectWeb('${widget.project.path}/-/packages/${widget.packageId}'),
              ownerKey: (widget.account.key, widget.api, widget.project.id, widget.packageId, _generation),
              isCurrent: () => _current(scope) && _downloadOwnerCurrent()),
          if (package?.canDelete == true && widget.project.archived != true)
            IconButton(
              tooltip: '刪除套件',
              onPressed: _busy ? null : _deletePackage,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: gestureSafe(
        package == null
            ? (_error == null
                  ? const ListSkeleton()
                  : SingleChildScrollView(
                      child: FailureNotice(
                        _error!,
                        account: widget.account,
                        resourceLabel:
                            '${widget.project.path} · 套件 #${widget.packageId}',
                        onRetry: _load,
                        onSwitchAccount: endSessionFrom(context),
                      ),
                    ))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PackageSummary(package: package),
                  Expanded(
                    child: RecordsFeed(
                      key: _files,
                      identity:
                          '${widget.account.key}/${widget.project.id}/package/${package.id}/files',
                      account: widget.account,
                      resourceLabel:
                          '${widget.project.path} · ${package.identity} · 檔案',
                      onSwitchAccount: endSessionFrom(context),
                      empty: '此套件沒有可顯示的檔案',
                      emptyIcon: Icons.description_outlined,
                      grouped: true,
                      load: (next) => widget.api.records(
                        [..._path, 'package_files'],
                        query: const {'order_by': 'created_at', 'sort': 'desc'},
                        next: next,
                      ),
                      itemBuilder: (context, value) {
                        late final RegistryPackageFile file;
                        try {
                          file = RegistryPackageFile.fromJson(value);
                        } on FormatException {
                          return const ListTile(title: Text('無法解析套件檔案'));
                        }
                        final blocked = packageFileDownloadBlockReason(
                          package,
                          file,
                        );
                        final ownerReady = _downloadOwnerCurrent();
                        final canonicalSha = RegExp(
                          r'^[0-9a-f]{64}$',
                        ).hasMatch(file.sha256);
                        final downloadEnabled = blocked == null && ownerReady;
                        final downloadTooltip =
                            blocked ??
                            (ownerReady
                                ? '下載並驗證 ${file.name}'
                                : '請從目前帳號工作階段重新開啟後下載');
                        return ListTile(
                          minTileHeight: 64,
                          leading: Icon(fileIconFor(file.name)),
                          title: Text(
                            file.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              registryBytes(file.size),
                              if (file.sha256.isNotEmpty)
                                'SHA-256 ${shortSha(file.sha256)}',
                              if (relativeDate(file.createdAt).isNotEmpty)
                                relativeDate(file.createdAt),
                              ?blocked,
                            ].join(' · '),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: downloadEnabled
                              ? () => unawaited(_downloadFile(package, file))
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: downloadTooltip,
                                onPressed: downloadEnabled
                                    ? () => unawaited(
                                        _downloadFile(package, file),
                                      )
                                    : null,
                                icon: const Icon(Icons.download_outlined),
                              ),
                              if (canonicalSha ||
                                  (package.canDelete &&
                                      widget.project.archived != true))
                                PopupMenuButton<String>(
                                  tooltip: '更多檔案動作',
                                  enabled: !_busy,
                                  onSelected: (value) {
                                    if (value == 'copy-sha') {
                                      unawaited(_copyFileSha(file));
                                    }
                                    if (value == 'delete') {
                                      unawaited(_deleteFile(file));
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    if (canonicalSha)
                                      PopupMenuItem(
                                        value: 'copy-sha',
                                        enabled: ownerReady,
                                        child: const Row(
                                          children: [
                                            Icon(Icons.copy_outlined),
                                            SizedBox(width: 12),
                                            Expanded(child: Text('複製 SHA-256')),
                                          ],
                                        ),
                                      ),
                                    if (package.canDelete &&
                                        widget.project.archived != true)
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            const Icon(Icons.delete_outline),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text('刪除 ${file.name}'),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                      footer: (_, _) => const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          '下載完成後會核對檔案大小與 SHA-256，驗證通過後才能開啟／分享。單一檔案上限為 256 MiB。',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PackageSummary extends StatelessWidget {
  const _PackageSummary({required this.package});
  final RegistryPackage package;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              package.identity,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                MetaChip(
                  packageTypeLabel(package.type),
                  icon: Icons.category_outlined,
                ),
                if (package.status.isNotEmpty)
                  MetaChip(package.status, icon: Icons.info_outline),
                if (relativeDate(package.createdAt).isNotEmpty)
                  MetaChip(
                    relativeDate(package.createdAt),
                    icon: Icons.schedule_outlined,
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ContainerRepositoriesTab extends StatefulWidget {
  const _ContainerRepositoriesTab({
    required this.account,
    required this.api,
    required this.project,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  @override
  State<_ContainerRepositoriesTab> createState() =>
      _ContainerRepositoriesTabState();
}

class _ContainerRepositoriesTabState extends State<_ContainerRepositoriesTab> {
  final _feed = GlobalKey<RecordsFeedState>();
  final _search = TextEditingController();
  int _ownerGeneration = 0;
  String _query = '';
  String _order = 'created_at';
  String _sort = 'desc';

  bool _visible(Json value) {
    final path = valueText(value, 'path');
    return _query.isEmpty || path.toLowerCase().contains(_query.toLowerCase());
  }

  List<Json> _arrange(List<Json> values) {
    final sorted = List<Json>.from(values);
    int compare(Json a, Json b) {
      return switch (_order) {
        'name' => valueText(
          a,
          'path',
        ).toLowerCase().compareTo(valueText(b, 'path').toLowerCase()),
        _ => valueText(a, 'created_at').compareTo(valueText(b, 'created_at')),
      };
    }

    sorted.sort((a, b) => _sort == 'asc' ? compare(a, b) : compare(b, a));
    return sorted;
  }

  @override
  void didUpdateWidget(covariant _ContainerRepositoriesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id) {
      _ownerGeneration++;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RecordsFeed(
    key: _feed,
    identity:
        '${widget.account.key}/${widget.project.id}/container-repositories/$_ownerGeneration',
    storageId:
        'registry/${widget.account.key}/${widget.project.id}/container-repositories/$_ownerGeneration',
    account: widget.account,
    resourceLabel: '${widget.project.path} · Container Registry',
    onSwitchAccount: endSessionFrom(context),
    empty: '尚無 Container 映像',
    emptyDetail: '推送第一個映像後，repository 會出現在這裡。',
    filteredEmpty: '已載入的 repository 中沒有符合項目',
    emptyIcon: Icons.view_in_ar_outlined,
    grouped: true,
    visible: _visible,
    arrange: _arrange,
    load: (next) => widget.api.records(
      ['projects', '${widget.project.id}', 'registry', 'repositories'],
      query: const {'tags_count': 'true'},
      next: next,
    ),
    leading: (_, _) => _RegistryToolbar(
      controller: _search,
      hint: '篩選已載入的 repository',
      onSubmitted: (value) => setState(() => _query = value.trim()),
      onSearch: () => setState(() => _query = _search.text.trim()),
      order: _order,
      sort: _sort,
      orders: const {'created_at': '建立時間', 'name': '名稱'},
      onOrder: (value) => setState(() => _order = value),
      onSort: (value) => setState(() => _sort = value),
      detail:
          'GitLab Container API 沒有 repository 搜尋參數；搜尋與排序套用在目前已載入頁面，可繼續「載入更多」。',
    ),
    itemBuilder: (context, value) {
      late final ContainerRepository repository;
      try {
        repository = ContainerRepository.fromJson(value);
      } on FormatException {
        return const ListTile(title: Text('無法解析 Container repository'));
      }
      return ListTile(
        minTileHeight: 68,
        leading: const Icon(Icons.view_in_ar_outlined),
        title: Text(
          repository.path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            '${repository.tagsCount} 個標籤',
            if (repository.status.isNotEmpty) repository.status,
            if (relativeDate(repository.createdAt).isNotEmpty)
              relativeDate(repository.createdAt),
          ].join(' · '),
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => ContainerRepositoryPage(
                account: widget.account,
                api: widget.api,
                project: widget.project,
                repositoryId: repository.id,
                initialPath: repository.path,
              ),
            ),
          );
          if (changed == true && mounted) {
            await _feed.currentState?.reconcileLoadedWindow();
          }
        },
      );
    },
  );
}

class ContainerRepositoryPage extends StatefulWidget {
  const ContainerRepositoryPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.repositoryId,
    required this.initialPath,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int repositoryId;
  final String initialPath;
  @override
  State<ContainerRepositoryPage> createState() =>
      _ContainerRepositoryPageState();
}

class _ContainerRepositoryPageState extends State<ContainerRepositoryPage> {
  final _tags = GlobalKey<RecordsFeedState>();
  ContainerRepository? _repository;
  ApiFailure? _error;
  int? _access;
  bool _busy = false;
  int _generation = 0;

  _RequestScope get _scope => _RequestScope(
    widget.account.key,
    widget.api,
    widget.project.id,
    _generation,
  );
  bool _current(_RequestScope scope) =>
      mounted &&
      scope.accountKey == widget.account.key &&
      identical(scope.api, widget.api) &&
      scope.projectId == widget.project.id &&
      scope.generation == _generation;
  List<String> get _detailPath => [
    'registry',
    'repositories',
    '${widget.repositoryId}',
  ];
  List<String> get _tagsPath => [
    'projects',
    '${widget.project.id}',
    'registry',
    'repositories',
    '${widget.repositoryId}',
    'tags',
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ContainerRepositoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.repositoryId != widget.repositoryId) {
      _generation++;
      _repository = null;
      _access = null;
      _error = null;
      _busy = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final scope = _scope;
    if (mounted) setState(() => _error = null);
    try {
      final value = await scope.api.record(
        _detailPath,
        query: const {'tags_count': 'true', 'size': 'true'},
      );
      final repository = ContainerRepository.fromJson(value);
      if (valueInt(value, 'project_id') != widget.project.id) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      int? access;
      try {
        access = await _effectiveAccess(
          widget.account,
          scope.api,
          widget.project,
        );
      } catch (_) {
        // Some instances allow the registry read but hide member details. Keep
        // the read-only page usable and require a fresh permission check before
        // any destructive action.
      }
      if (_current(scope)) {
        setState(() {
          _repository = repository;
          _access = access;
        });
      }
    } catch (error) {
      if (_current(scope)) setState(() => _error = safeFailure(error));
    }
  }

  Future<void> _deleteRepository() async {
    if (_busy) return;
    final scope = _scope;
    try {
      final freshJson = await scope.api.record(
        _detailPath,
        query: const {'tags_count': 'true', 'size': 'true'},
      );
      final fresh = ContainerRepository.fromJson(freshJson);
      final access = await _effectiveAccess(
        widget.account,
        scope.api,
        widget.project,
      );
      if (!_current(scope)) return;
      if (valueInt(freshJson, 'project_id') != widget.project.id ||
          access < _maintainerAccess ||
          widget.project.archived == true) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      if (!mounted) return;
      if (!await confirmAction(
            context,
            '刪除 Container repository？',
            'GitLab 會非同步刪除 ${fresh.path} 與其中所有標籤。Registry 儲存空間可能要等垃圾回收後才釋放。',
            requiredText: fresh.path,
          ) ||
          !_current(scope)) {
        return;
      }
      setState(() => _busy = true);
      await scope.api.removeRecord([
        'projects',
        '${widget.project.id}',
        'registry',
        'repositories',
        '${widget.repositoryId}',
      ]);
      if (!_current(scope)) return;
      try {
        final readback = ContainerRepository.fromJson(
          await scope.api.record(_detailPath),
        );
        if (_current(scope)) setState(() => _repository = readback);
      } on ApiFailure catch (failure) {
        if (failure.status != 404) rethrow;
      }
      if (_current(scope) && mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (_current(scope) && mounted) showFailure(context, error);
    } finally {
      if (_current(scope)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    final canDelete =
        (_access ?? 0) >= _maintainerAccess && widget.project.archived != true;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          repository?.name.isNotEmpty == true
              ? repository!.name
              : widget.initialPath,
        ),
        actions: [
          if (canDelete)
            IconButton(
              tooltip: '刪除 Container repository',
              onPressed: _busy ? null : _deleteRepository,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: gestureSafe(
        repository == null
            ? (_error == null
                  ? const ListSkeleton()
                  : SingleChildScrollView(
                      child: FailureNotice(
                        _error!,
                        account: widget.account,
                        resourceLabel:
                            '${widget.project.path} · Container ${widget.initialPath}',
                        onRetry: _load,
                        onSwitchAccount: endSessionFrom(context),
                      ),
                    ))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              repository.location.isEmpty
                                  ? repository.path
                                  : repository.location,
                              style: codeTextStyle(context, fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              runSpacing: 6,
                              children: [
                                MetaChip(
                                  '${repository.tagsCount} 個標籤',
                                  icon: Icons.sell_outlined,
                                ),
                                MetaChip(
                                  registryBytes(repository.size),
                                  icon: Icons.storage_outlined,
                                ),
                                if (repository.status.isNotEmpty)
                                  MetaChip(
                                    repository.status,
                                    icon: Icons.info_outline,
                                  ),
                              ],
                            ),
                            if (!canDelete) ...[
                              const SizedBox(height: 10),
                              Text(
                                _access == null
                                    ? '此實例未提供目前帳號的有效角色；刪除功能保持停用。'
                                    : '刪除需要目前帳號具備 Maintainer 以上的有效專案角色。',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: RecordsFeed(
                      key: _tags,
                      identity:
                          '${widget.account.key}/${widget.project.id}/container/${widget.repositoryId}/tags',
                      account: widget.account,
                      resourceLabel:
                          '${widget.project.path} · ${repository.path} · 標籤',
                      onSwitchAccount: endSessionFrom(context),
                      empty: '這個 repository 沒有標籤',
                      emptyIcon: Icons.sell_outlined,
                      grouped: true,
                      load: (next) => widget.api.records(_tagsPath, next: next),
                      itemBuilder: (context, value) {
                        late final ContainerTag tag;
                        try {
                          tag = ContainerTag.fromJson(value);
                        } on FormatException {
                          return const ListTile(
                            title: Text('無法解析 Container 標籤'),
                          );
                        }
                        return ListTile(
                          minTileHeight: 58,
                          leading: const Icon(Icons.sell_outlined),
                          title: Text(
                            tag.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: tag.location.isEmpty
                              ? null
                              : Text(
                                  tag.location,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () async {
                            final deleted = await Navigator.of(context)
                                .push<bool>(
                                  MaterialPageRoute(
                                    builder: (_) => ContainerTagPage(
                                      account: widget.account,
                                      api: widget.api,
                                      project: widget.project,
                                      repositoryId: widget.repositoryId,
                                      repositoryPath: repository.path,
                                      tagName: tag.name,
                                      canDelete: canDelete,
                                    ),
                                  ),
                                );
                            if (deleted == true && mounted) {
                              await _tags.currentState?.reconcileLoadedWindow();
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class ContainerTagPage extends StatefulWidget {
  const ContainerTagPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.repositoryId,
    required this.repositoryPath,
    required this.tagName,
    required this.canDelete,
  });
  final Account account;
  final GitLabApi api;
  final Project project;
  final int repositoryId;
  final String repositoryPath, tagName;
  final bool canDelete;
  @override
  State<ContainerTagPage> createState() => _ContainerTagPageState();
}

class _ContainerTagPageState extends State<ContainerTagPage> {
  ContainerTag? _tag;
  ApiFailure? _error;
  bool _busy = false;
  int _generation = 0;

  _RequestScope get _scope => _RequestScope(
    widget.account.key,
    widget.api,
    widget.project.id,
    _generation,
  );
  bool _current(_RequestScope scope) =>
      mounted &&
      scope.accountKey == widget.account.key &&
      identical(scope.api, widget.api) &&
      scope.projectId == widget.project.id &&
      scope.generation == _generation;
  List<String> get _path => [
    'projects',
    '${widget.project.id}',
    'registry',
    'repositories',
    '${widget.repositoryId}',
    'tags',
    widget.tagName,
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ContainerTagPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.repositoryId != widget.repositoryId ||
        oldWidget.tagName != widget.tagName) {
      _generation++;
      _tag = null;
      _error = null;
      _busy = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final scope = _scope;
    try {
      final tag = ContainerTag.fromJson(await scope.api.record(_path));
      if (_current(scope)) {
        setState(() {
          _tag = tag;
          _error = null;
        });
      }
    } catch (error) {
      if (_current(scope)) setState(() => _error = safeFailure(error));
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final scope = _scope;
    try {
      final access = await _effectiveAccess(
        widget.account,
        scope.api,
        widget.project,
      );
      final fresh = ContainerTag.fromJson(await scope.api.record(_path));
      if (!_current(scope)) return;
      if (access < _maintainerAccess || widget.project.archived == true) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      if (!mounted) return;
      if (!await confirmAction(
            context,
            '刪除 Container 標籤？',
            '${widget.repositoryPath}:${fresh.name}\n此操作不會立即刪除共用 blob。',
            requiredText: fresh.name,
          ) ||
          !_current(scope)) {
        return;
      }
      setState(() => _busy = true);
      await scope.api.removeRecord(_path);
      if (!_current(scope)) return;
      try {
        await scope.api.record(_path);
        throw const ApiFailure(FailureKind.writeUncertain);
      } on ApiFailure catch (failure) {
        if (failure.status != 404) rethrow;
      }
      if (_current(scope) && mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (_current(scope) && mounted) showFailure(context, error);
    } finally {
      if (_current(scope)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tag = _tag;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tagName),
        actions: [
          if (widget.canDelete && widget.project.archived != true)
            IconButton(
              tooltip: '刪除標籤',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: gestureSafe(
        tag == null
            ? (_error == null
                  ? const ListSkeleton()
                  : SingleChildScrollView(
                      child: FailureNotice(
                        _error!,
                        account: widget.account,
                        resourceLabel:
                            '${widget.project.path} · ${widget.repositoryPath}:${widget.tagName}',
                        onRetry: _load,
                        onSwitchAccount: endSessionFrom(context),
                      ),
                    ))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${widget.repositoryPath}:${tag.name}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 14),
                          _DetailRow('大小', registryBytes(tag.size)),
                          _DetailRow(
                            '建立',
                            relativeDate(tag.createdAt).isEmpty
                                ? '未知'
                                : relativeDate(tag.createdAt),
                          ),
                          _DetailRow(
                            'Digest',
                            tag.digest.isEmpty ? '未提供' : tag.digest,
                            mono: true,
                          ),
                          _DetailRow(
                            'Revision',
                            tag.revision.isEmpty ? '未提供' : tag.revision,
                            mono: true,
                          ),
                          _DetailRow(
                            '位置',
                            tag.location.isEmpty ? '未提供' : tag.location,
                            mono: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value, {this.mono = false});
  final String label, value;
  final bool mono;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: mono ? codeTextStyle(context, fontSize: 12) : null,
        ),
      ],
    ),
  );
}
