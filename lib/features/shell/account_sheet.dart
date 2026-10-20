import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';

import '../../l10n/l10n.dart';
/// The avatar menu: the signed-in identity, the other saved accounts and an
/// entry to add or reconnect one. Switching re-validates through
/// [SessionController.select]; nothing here rotates accounts on its own.
Future<void> showAccountSheet(BuildContext context, SessionController session) {
  final account = session.active;
  if (account == null) return Future<void>.value();
  return showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (sheetContext) {
    final theme = Theme.of(sheetContext);
    return SafeArea(child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
      Row(children: [
        Monogram(account.user.name, size: 48, circle: true),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(account.user.name, style: theme.textTheme.titleMedium),
          Text(isolated('@${account.user.username}'), style: theme.textTheme.bodyMedium),
          Text(account.instance.key, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ])),
      ]),
      const SizedBox(height: 12),
      for (final saved in session.accounts.where((saved) => saved.key != account.key))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Monogram(saved.user.name, size: 32, circle: true),
          title: Text(isolated('@${saved.user.username}'), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(saved.instance.base.host),
          trailing: const Icon(Icons.swap_horiz),
          onTap: session.busy ? null : () {
            Navigator.pop(sheetContext);
            unawaited(session.select(saved));
          },
        ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.person_add_outlined),
        title: Text(l10n.addOrSwitchAccount),
        onTap: () {
          Navigator.pop(sheetContext);
          unawaited(session.endSession());
        },
      ),
    ]));
  });
}

/// The round avatar button in root app bars; opens [showAccountSheet].
class AccountAvatarButton extends StatelessWidget {
  const AccountAvatarButton({super.key, required this.session});
  final SessionController session;
  @override
  Widget build(BuildContext context) {
    final account = session.active;
    if (account == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: l10n.accountAtUsername(account.user.username),
      onPressed: () => showAccountSheet(context, session),
      icon: Monogram(account.user.name, size: 30, circle: true),
    );
  }
}
