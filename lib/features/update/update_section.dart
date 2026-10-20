import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/artifact_storage.dart' show formatByteCount;
import '../../shared/hub_ui.dart';
import 'app_update.dart';
import 'update_controller.dart';
import '../../core/brand.dart';

import '../../l10n/l10n.dart';
/// 我的 › 應用程式更新: where this build gets its updates, the current
/// state, the one action that moves it forward, and the start-up check.
class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key, required this.controller});
  final AppUpdateController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final muted = theme.colorScheme.onSurfaceVariant;
      final gitlab = controller.channel == UpdateChannel.gitlab;
      final (title, subtitle) = _describe();
      final progress = controller.progress;
      return HubSection(
        title: l10n.appUpdatesLabel,
        children: [
          ListTile(
            key: const ValueKey('app-update-status'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: const IconTile(Icons.system_update_outlined, color: HubColors.green),
            title: Text(title),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: _action(context),
          ),
          if (controller.stage == UpdateStage.downloading && gitlab)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: LinearProgressIndicator(
                value: progress == null || (progress.$2 ?? 0) <= 0 ? null : progress.$1 / progress.$2!,
              ),
            ),
          SwitchListTile(
            key: const ValueKey('app-update-auto-check'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(l10n.checkUpdatesOnLaunch),
            value: controller.autoCheck,
            onChanged: (value) => unawaited(controller.setAutoCheck(value)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              gitlab
                  ? l10n.anonymousReleaseShaVerifyHint
                  : l10n.updatesViaGooglePlay,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      );
    },
  );

  (String, String?) _describe() {
    final current = controller.currentCode == null ? null : l10n.currentVersionCode(controller.currentCode);
    final release = controller.release;
    final play = controller.channel == UpdateChannel.play;
    return switch (controller.stage) {
      UpdateStage.idle => (l10n.checkForUpdates, current),
      UpdateStage.checking => (l10n.checkingForUpdates, current),
      UpdateStage.upToDate => (l10n.alreadyUpToDate, current),
      UpdateStage.available when play => (l10n.newVersionOnGooglePlay,
        controller.playVersionCode == null ? current : l10n.playVersionCodeLabel(controller.playVersionCode)),
      UpdateStage.available => (l10n.newVersionValue(release?.label ?? ''), release == null ? null
          : [if (release.commit.isNotEmpty) 'commit ${release.commit.substring(0, release.commit.length.clamp(0, 8))}',
             formatByteCount(release.file.size)].join(' · ')),
      UpdateStage.downloading when play => (l10n.playDownloadingUpdate, null),
      UpdateStage.downloading => (l10n.downloadingValue(release?.label ?? ''), _percent()),
      UpdateStage.downloaded when play => (l10n.updateDownloaded, l10n.restartAppToFinishUpdate),
      UpdateStage.downloaded => (l10n.downloadedVerifiedValue(release?.label ?? ''), controller.needsPermission
          ? l10n.allowInstallThenTapInstall(appName)
          : l10n.tapInstallThenAndroidConfirms),
      UpdateStage.installing => (l10n.openingInstaller, null),
      UpdateStage.failed => (controller.failure?.title ?? l10n.updateFailed, controller.failure?.detail),
    };
  }

  String? _percent() {
    final progress = controller.progress;
    final total = progress?.$2;
    if (progress == null || total == null || total <= 0) return null;
    return '${(progress.$1 * 100 / total).floor()}% · ${formatByteCount(progress.$1)} / ${formatByteCount(total)}';
  }

  Widget? _action(BuildContext context) {
    final play = controller.channel == UpdateChannel.play;
    return switch (controller.stage) {
      UpdateStage.checking || UpdateStage.installing =>
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      UpdateStage.available => FilledButton(
        key: const ValueKey('app-update-download'),
        onPressed: () => unawaited(controller.download()),
        child: Text(play ? l10n.updateAction : l10n.downloadAction),
      ),
      UpdateStage.downloading when !play => TextButton(
        onPressed: controller.cancelDownload,
        child: Text(l10n.cancelAction),
      ),
      UpdateStage.downloading => null,
      UpdateStage.downloaded => FilledButton(
        key: const ValueKey('app-update-install'),
        onPressed: () => unawaited(controller.install()),
        child: Text(play ? l10n.restartAction : l10n.installAction),
      ),
      UpdateStage.failed => TextButton(
        onPressed: () => unawaited(controller.check()),
        child: Text(l10n.retryAction),
      ),
      _ => TextButton(
        key: const ValueKey('app-update-check'),
        onPressed: () => unawaited(controller.check()),
        child: Text(l10n.checkAction),
      ),
    };
  }
}
