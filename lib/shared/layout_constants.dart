import 'package:flutter/painting.dart';

/// Shared geometry constants used across hub lists and skeleton placeholders
/// without introducing a library cycle between `skeleton.dart`, `hub_ui.dart`,
/// and `workspace_ui.dart`.
abstract final class SharedLayout {
  /// The page gutter: the inset of rows, fields and section headings.
  static const double gutter = 16;

  /// The vertical gap between two stacked form fields.
  static const double fieldGap = 16;

  /// The leading slot of a hub row or list tile (a 32 dp tile).
  static const double leadingSlot = 32;

  /// The gap between the leading slot and the row's text.
  static const double leadingGap = 16;

  /// Where a row's text starts: gutter, leading slot and gap. Dividers and
  /// details under a row's text indent by this much.
  static const double rowTextInset = gutter + leadingSlot + leadingGap;

  /// Minimum height of a section heading, so headings with and without a
  /// 48 dp trailing action sit at the same height.
  static const double headingMinHeight = 48;

  /// Standard padding for [HubRow] and [HomeSectionSkeleton] rows.
  static const EdgeInsets hubRowPadding = EdgeInsets.symmetric(
    horizontal: gutter,
    vertical: 8,
  );
}
