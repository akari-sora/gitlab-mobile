import 'package:flutter/material.dart';
import '../core/failure.dart';
import '../core/models.dart';

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.failure, this.account,
    this.onRetry, this.onSwitchAccount, this.onOpenBrowser, this.resourceLabel, this.compact = false});
  final ApiFailure failure;
  final Account? account;
  final String? resourceLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onSwitchAccount;
  final VoidCallback? onOpenBrowser;
  final bool compact;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.all(16),
    child: Padding(padding: const EdgeInsets.all(16), child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline), const SizedBox(height: 12),
        Text(failure.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8), Text(failure.detail),
        if (account != null) ...[
          const SizedBox(height: 12),
          Text('實例：${account!.instance.key}'),
          Text('App 帳號：@${account!.user.username}'),
        ],
        if (resourceLabel != null) Text('目標：$resourceLabel'),
        if (failure.retryAt != null) Text('可重試時間：${failure.retryAt!.toLocal()}'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          if (onRetry != null) TextButton.icon(onPressed: onRetry,
            icon: const Icon(Icons.refresh), label: const Text('重新檢查')),
          if (onSwitchAccount != null) TextButton(onPressed: onSwitchAccount, child: const Text('切換帳號')),
          if (onOpenBrowser != null) TextButton(onPressed: onOpenBrowser, child: const Text('瀏覽器開啟')),
        ]),
      ],
    )),
  );
}
