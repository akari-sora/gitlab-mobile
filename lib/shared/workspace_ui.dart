import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/providers.dart';

/// Ends the active session so the user can pick another account. Does not rotate accounts.
VoidCallback endSessionFrom(BuildContext context) => () {
  try {
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionProvider).endSession();
  } catch (_) {}
};

String valueText(Json value, String key, [String fallback = '']) =>
    value[key] is String ? value[key] as String : fallback;
int valueInt(Json value, String key) =>
    value[key] is int ? value[key] as int : 0;
Json valueObject(Json value, String key) => value[key] is Map<String, dynamic>
    ? value[key] as Json
    : <String, dynamic>{};
List<Json> valueObjects(Json value, String key) =>
    value[key] is List ? (value[key] as List).whereType<Json>().toList() : [];
String shortSha(String sha) => sha.length > 8 ? sha.substring(0, 8) : sha;
/// Keeps a scrolling body clear of the gesture bar and of side insets from
/// landscape navigation or a display cutout. The app bar already owns the top.
Widget gestureSafe(Widget child) => SafeArea(top: false, child: child);

String relativeDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return '';
  final diff = DateTime.now().difference(parsed);
  if (diff.inMinutes < 1) return '剛剛';
  if (diff.inHours < 1) return '${diff.inMinutes} 分鐘前';
  if (diff.inDays < 1) return '${diff.inHours} 小時前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final date = parsed.toLocal();
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (status) {
      'opened' => ('開啟中', Icons.adjust),
      'closed' => ('已關閉', Icons.check_circle_outline),
      'merged' => ('已合併', Icons.merge),
      'success' || 'passed' => ('成功', Icons.check_circle_outline),
      'failed' => ('失敗', Icons.error_outline),
      'running' => ('執行中', Icons.motion_photos_on_outlined),
      'pending' ||
      'created' ||
      'waiting_for_resource' ||
      'preparing' => ('等待中', Icons.schedule),
      'canceled' => ('已取消', Icons.cancel_outlined),
      'skipped' => ('已略過', Icons.skip_next_outlined),
      'manual' => ('等待手動啟動', Icons.play_circle_outline),
      'private' => ('私有', Icons.lock_outline),
      'internal' => ('內部', Icons.business_outlined),
      'public' => ('公開', Icons.public),
      _ => (status.isEmpty ? '狀態未知' : status, Icons.info_outline),
    };
    final scheme = Theme.of(context).colorScheme;
    final error = status == 'failed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: error ? scheme.onErrorContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: error
                    ? scheme.onErrorContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class Monogram extends StatelessWidget {
  const Monogram(this.name, {super.key, this.size = 42});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(size * .28),
    ),
    child: Text(
      name.isEmpty ? 'G' : name.characters.first.toUpperCase(),
      style: TextStyle(
        fontSize: size * .4,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState(
    this.title, {
    super.key,
    this.detail,
    this.icon = Icons.inbox_outlined,
    this.action,
  });
  final String title;
  final String? detail;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 36,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

class FailureNotice extends StatelessWidget {
  const FailureNotice(
    this.error, {
    super.key,
    this.account,
    this.resourceLabel,
    this.onRetry,
    this.onSwitchAccount,
  });
  final ApiFailure error;
  final Account? account;
  final String? resourceLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onSwitchAccount;
  @override
  Widget build(BuildContext context) {
    Account? effectiveAccount = account;
    VoidCallback? effectiveSwitch = onSwitchAccount;
    if (effectiveAccount == null || effectiveSwitch == null) {
      try {
        final session = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(sessionProvider);
        effectiveAccount ??= session.active;
        effectiveSwitch ??= session.endSession;
      } catch (_) {}
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      error.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(error.detail),
              if (effectiveAccount != null) ...[
                const SizedBox(height: 12),
                Text('實例：${effectiveAccount.instance.key}'),
                Text('App 帳號：@${effectiveAccount.user.username}'),
              ],
              if (resourceLabel != null && resourceLabel!.isNotEmpty)
                Text('目標：$resourceLabel'),
              Wrap(
                spacing: 8,
                children: [
                  if (onRetry != null &&
                      error.kind != FailureKind.writeUncertain)
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新整理'),
                    ),
                  if (effectiveSwitch != null)
                    TextButton(
                      onPressed: effectiveSwitch,
                      child: const Text('切換帳號'),
                    ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('診斷資訊', style: TextStyle(fontSize: 12)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      '${error.kind.name}${error.status == null ? '' : ' · HTTP ${error.status}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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

class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在載入',
    liveRegion: true,
    child: const Padding(
      padding: EdgeInsets.all(32),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String detail, {
  String? requiredText,
}) async {
  final input = TextEditingController();
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail),
              if (requiredText != null) ...[
                const SizedBox(height: 16),
                Text('輸入「$requiredText」確認'),
                const SizedBox(height: 8),
                TextField(
                  controller: input,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: '確認名稱'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: requiredText != null && input.text != requiredText
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('確認'),
          ),
        ],
      ),
    ),
  );
  // The route may still be animating out; do not dispose its controller early.
  Future<void>.delayed(const Duration(milliseconds: 400), input.dispose);
  return answer ?? false;
}

void showFailure(BuildContext context, Object error) {
  final failure = safeFailure(error);
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('${failure.title}。${failure.detail}')));
}
