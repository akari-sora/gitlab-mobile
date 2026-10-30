import 'package:flutter/material.dart';

import '../../core/instance.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';

/// The demo's GitLab host. `.invalid` is reserved (RFC 6761), so no real
/// instance can share it and no request to it can resolve.
const demoHost = 'demo.mergeline.invalid';

final GitLabInstance demoInstance = GitLabInstance.parse('https://$demoHost');

/// Whether [account] is the built-in demo account. Stores that write to the
/// device check this so the demo never leaves anything behind.
bool isDemoAccount(Account account) => isDemoInstance(account.instance);

bool isDemoInstance(GitLabInstance instance) => instance.base.host == demoHost;

/// Marks the demo subtree. It sits above the demo's [MaterialApp], so every
/// route in the demo sees it; outside the demo [maybeOf] is null.
class DemoScope extends InheritedWidget {
  const DemoScope({super.key, required this.exit, required super.child});

  /// Leaves the demo and returns to the sign-in screen.
  final Future<void> Function() exit;

  static DemoScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DemoScope>();

  @override
  bool updateShouldNotify(DemoScope oldWidget) => exit != oldWidget.exit;
}

/// A strip above every demo page, including dialogs, that says the data is
/// sample data. It takes over the status bar inset from [child].
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.child});

  final Widget child;

  /// [child] with the banner when [context] is inside the demo.
  static Widget wrap(BuildContext context, Widget? child) {
    final page = child ?? const SizedBox.shrink();
    return DemoScope.maybeOf(context) == null ? page : DemoBanner(child: page);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: scheme.onTertiaryContainer,
      fontWeight: FontWeight.w600,
    );
    return Column(
      children: [
        Material(
          key: const ValueKey('demo-banner'),
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              padding.left + 16,
              padding.top + 4,
              padding.right + 16,
              4,
            ),
            child: Semantics(
              container: true,
              label: l10n.demoBanner,
              child: ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.science_outlined,
                      size: 16,
                      color: scheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        l10n.demoBanner,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
