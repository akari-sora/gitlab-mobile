import 'package:flutter/painting.dart';

/// Shared geometry constants used across hub lists and skeleton placeholders
/// without introducing a library cycle between `skeleton.dart`, `hub_ui.dart`,
/// and `workspace_ui.dart`.
abstract final class SharedLayout {
  /// Standard padding for [HubRow] and [HomeSectionSkeleton] rows.
  static const EdgeInsets hubRowPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 8,
  );
}
