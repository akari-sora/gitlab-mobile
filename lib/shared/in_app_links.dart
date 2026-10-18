import 'package:flutter/widgets.dart';

/// Opens a tapped web link inside the app when it names a resource the app
/// has a screen for. Returns false to leave the link to the system browser.
typedef InAppLinkHandler = Future<bool> Function(BuildContext context, Uri uri);

/// Carries the signed-in app's [InAppLinkHandler] to every route below it, so
/// shared widgets such as Markdown can open GitLab links in the app without
/// depending on the feature screens.
class InAppLinks extends InheritedWidget {
  const InAppLinks({super.key, required this.handler, required super.child});

  final InAppLinkHandler handler;

  /// The nearest handler. A link is resolved when it is tapped, so [context]
  /// does not subscribe to changes.
  static InAppLinkHandler? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<InAppLinks>()?.handler;

  @override
  bool updateShouldNotify(InAppLinks oldWidget) => handler != oldWidget.handler;
}
