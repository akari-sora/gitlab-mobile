import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/artifact_storage.dart' show formatByteCount;
import '../../shared/hub_ui.dart';
import 'app_update.dart';
import 'update_controller.dart';

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
        title: '應用程式更新',
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
            title: const Text('啟動時自動檢查更新'),
            value: controller.autoCheck,
            onChanged: (value) => unawaited(controller.setAutoCheck(value)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              gitlab
                  ? '從 GitLab 上本 App 的 Releases 匿名檢查，不送出你的 Token；下載後以 GitLab 記錄的 SHA-256 驗證，再交給 Android 安裝程式由你確認。'
                  : '透過 Google Play 下載與安裝更新。',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      );
    },
  );

  (String, String?) _describe() {
    final current = controller.currentCode == null ? null : '目前版本 (${controller.currentCode})';
    final release = controller.release;
    final play = controller.channel == UpdateChannel.play;
    return switch (controller.stage) {
      UpdateStage.idle => ('檢查更新', current),
      UpdateStage.checking => ('正在檢查更新…', current),
      UpdateStage.upToDate => ('已是最新版本', current),
      UpdateStage.available when play => ('Google Play 有新版本',
        controller.playVersionCode == null ? current : '版本代碼 ${controller.playVersionCode}'),
      UpdateStage.available => ('有新版本 ${release?.label ?? ''}', release == null ? null
          : [if (release.commit.isNotEmpty) 'commit ${release.commit.substring(0, release.commit.length.clamp(0, 8))}',
             formatByteCount(release.file.size)].join(' · ')),
      UpdateStage.downloading when play => ('Google Play 正在下載更新…', null),
      UpdateStage.downloading => ('正在下載 ${release?.label ?? ''}', _percent()),
      UpdateStage.downloaded when play => ('更新已下載', '重新啟動 App 即可完成更新。'),
      UpdateStage.downloaded => ('已下載並驗證 ${release?.label ?? ''}', controller.needsPermission
          ? '請在系統設定允許 GitLab Mobile 安裝應用程式，返回後再點「安裝」。'
          : '點「安裝」後由 Android 安裝程式確認。'),
      UpdateStage.installing => ('正在開啟安裝程式…', null),
      UpdateStage.failed => (controller.failure?.title ?? '更新失敗', controller.failure?.detail),
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
        child: Text(play ? '更新' : '下載'),
      ),
      UpdateStage.downloading when !play => TextButton(
        onPressed: controller.cancelDownload,
        child: const Text('取消'),
      ),
      UpdateStage.downloading => null,
      UpdateStage.downloaded => FilledButton(
        key: const ValueKey('app-update-install'),
        onPressed: () => unawaited(controller.install()),
        child: Text(play ? '重新啟動' : '安裝'),
      ),
      UpdateStage.failed => TextButton(
        onPressed: () => unawaited(controller.check()),
        child: const Text('重試'),
      ),
      _ => TextButton(
        key: const ValueKey('app-update-check'),
        onPressed: () => unawaited(controller.check()),
        child: const Text('檢查'),
      ),
    };
  }
}
