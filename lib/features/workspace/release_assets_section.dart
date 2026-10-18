import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/release_assets.dart';
import '../../shared/artifact_storage.dart';
import '../../shared/attachment_download.dart';
import '../../shared/attachment_ref.dart';
import '../../shared/external_link.dart';
import '../../shared/hub_ui.dart';
import '../../shared/package_download.dart';

/// How the app can fetch one release link.
enum ReleaseLinkAction { package, upload, browser, blocked }

ReleaseLinkAction releaseLinkAction(ReleaseAssetLink link, {required Account account, required Project project}) {
  final web = account.instance.projectWeb(project.path);
  if (parseReleasePackageLink(link.url, instance: account.instance, projectId: project.id, projectPath: project.path) != null) {
    return ReleaseLinkAction.package;
  }
  if (parseProjectUpload(link.url, base: web, projectId: project.id, projectWeb: web) != null) {
    return ReleaseLinkAction.upload;
  }
  return safeExternalUri(link.url) ? ReleaseLinkAction.browser : ReleaseLinkAction.blocked;
}

/// A release's links and source archives. Generic package files of this
/// project download in the app with their recorded SHA-256 checked, project
/// uploads download like Markdown attachments, and anything else opens in the
/// browser so no credential reaches another host.
class ReleaseAssetsSection extends StatefulWidget {
  const ReleaseAssetsSection({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    required this.assets,
    required this.isCurrent,
    this.ownerChanges,
    this.packageDownloader,
    this.sharer = const SystemArtifactSharer(),
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final ReleaseAssets assets;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;
  final PackageDownloader? packageDownloader;
  final ArtifactSharer sharer;

  @override
  State<ReleaseAssetsSection> createState() => _ReleaseAssetsSectionState();
}

class _ReleaseAssetsSectionState extends State<ReleaseAssetsSection> {
  int? _resolving;
  int _epoch = 0;

  @override
  void didUpdateWidget(covariant ReleaseAssetsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project.id != widget.project.id) {
      _epoch++;
      _resolving = null;
    }
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  bool _current(int epoch) => mounted && epoch == _epoch && !widget.api.isClosed && widget.isCurrent();

  Future<void> _open(int index, ReleaseAssetLink link) async {
    if (_resolving != null || !widget.isCurrent()) return;
    switch (releaseLinkAction(link, account: widget.account, project: widget.project)) {
      case ReleaseLinkAction.package:
        await _downloadPackage(index, link);
      case ReleaseLinkAction.upload:
        final web = widget.account.instance.projectWeb(widget.project.path);
        final upload = parseProjectUpload(link.url, base: web, projectId: widget.project.id, projectWeb: web)!;
        await showAttachmentDownloadSheet(
          context,
          api: widget.api,
          projectId: widget.project.id,
          secret: upload.secret,
          filename: upload.filename,
          account: widget.account,
          projectPath: widget.project.path,
          webUri: link.url,
          sharer: widget.sharer,
        );
      case ReleaseLinkAction.browser:
        await openExternal(context, link.url);
      case ReleaseLinkAction.blocked:
        return;
    }
  }

  Future<void> _downloadPackage(int index, ReleaseAssetLink link) async {
    final target = parseReleasePackageLink(link.url,
        instance: widget.account.instance, projectId: widget.project.id, projectPath: widget.project.path)!;
    final epoch = _epoch;
    setState(() => _resolving = index);
    try {
      final (package, file) =
          await widget.api.releasePackageFile(widget.project.id, target, isCurrent: () => _current(epoch));
      if (!mounted || !_current(epoch)) return;
      setState(() => _resolving = null);
      await showPackageDownloadSheet(
        context,
        account: widget.account,
        api: widget.api,
        project: widget.project,
        package: package,
        file: file,
        isCurrent: () => _current(epoch),
        ownerChanges: widget.ownerChanges,
        downloader: widget.packageDownloader,
        sharer: widget.sharer,
      );
    } catch (error) {
      if (!mounted || !_current(epoch)) return;
      setState(() => _resolving = null);
      final failure = safeFailure(error);
      if (failure.kind == FailureKind.cancelled) return;
      final shown = failure.kind == FailureKind.invisible
          ? const ApiFailure(FailureKind.invisible,
              title: '找不到這個套件檔案', detail: '套件可能已刪除，或目前帳號沒有權限讀取。')
          : failure;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${shown.title}。${shown.detail}'),
        action: safeExternalUri(link.url)
            ? SnackBarAction(label: '在瀏覽器開啟', onPressed: () => unawaited(openExternal(context, link.url)))
            : null,
      ));
    } finally {
      if (mounted && epoch == _epoch && _resolving == index) setState(() => _resolving = null);
    }
  }

  static IconData _icon(String linkType) => switch (linkType) {
    'package' => Icons.inventory_2_outlined,
    'image' => Icons.image_outlined,
    'runbook' => Icons.menu_book_outlined,
    _ => Icons.insert_drive_file_outlined,
  };

  Widget _linkRow(int index, ReleaseAssetLink link) {
    final action = releaseLinkAction(link, account: widget.account, project: widget.project);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final resolving = _resolving == index;
    final subtitle = switch (action) {
      ReleaseLinkAction.package => '套件檔案 · 下載後核對 SHA-256',
      ReleaseLinkAction.upload => '專案附件 · 在 App 內下載',
      ReleaseLinkAction.browser => '${link.url.host} · 在瀏覽器開啟',
      ReleaseLinkAction.blocked => '不是 HTTPS 連結，無法開啟',
    };
    final Widget trailing = resolving
        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(
            switch (action) {
              ReleaseLinkAction.package || ReleaseLinkAction.upload => Icons.download_outlined,
              ReleaseLinkAction.browser => Icons.open_in_new,
              ReleaseLinkAction.blocked => Icons.block,
            },
            size: 20,
            color: muted,
          );
    return HubRow(
      key: ValueKey('release-link-$index'),
      leading: NeutralTile(_icon(link.linkType)),
      title: link.name,
      subtitle: subtitle,
      trailing: Padding(padding: const EdgeInsets.only(left: 8), child: trailing),
      onTap: action == ReleaseLinkAction.blocked || _resolving != null ? null : () => unawaited(_open(index, link)),
    );
  }

  Widget _sourceRow(ReleaseSource source) => HubRow(
    key: ValueKey('release-source-${source.format}'),
    leading: const NeutralTile(Icons.folder_zip_outlined),
    title: '原始碼（${source.format}）',
    subtitle: '在瀏覽器下載',
    trailing: Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Icon(Icons.open_in_new, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    onTap: safeExternalUri(source.url) ? () => unawaited(openExternal(context, source.url)) : null,
  );

  @override
  Widget build(BuildContext context) {
    final assets = widget.assets;
    return HubSection(
      title: '附件',
      children: [
        for (var i = 0; i < assets.links.length; i++) _linkRow(i, assets.links[i]),
        for (final source in assets.sources) _sourceRow(source),
      ],
    );
  }
}
