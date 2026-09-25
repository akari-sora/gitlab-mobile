import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as mui;

/// Transparent edge-to-edge bars whose icons contrast with [surface].
/// Light surfaces get dark icons; dark surfaces get light icons.
SystemUiOverlayStyle systemUiOverlayStyle(Brightness surface) {
  final lightSurface = surface == Brightness.light;
  final icons = lightSurface ? Brightness.dark : Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: const Color(0x00000000),
    statusBarBrightness: lightSurface ? Brightness.light : Brightness.dark,
    statusBarIconBrightness: icons,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: const Color(0x00000000),
    systemNavigationBarDividerColor: const Color(0x00000000),
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
  );
}

/// Keeps the status and navigation icons in sync with the resolved theme,
/// including screens that have no [AppBar].
Widget applySystemBars(BuildContext context, Widget? child) {
  final style = systemUiOverlayStyle(Theme.of(context).brightness);
  SystemChrome.setSystemUIOverlayStyle(style);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: style,
    child: child ?? const SizedBox.shrink(),
  );
}

/// `dynamic_color` 2.1 reports schemes from `material_ui`, which is not the
/// Flutter [ColorScheme] [ThemeData] consumes. Copy the roles we theme with.
ColorScheme? flutterScheme(mui.ColorScheme? scheme) {
  if (scheme == null) {
    return null;
  }
  return ColorScheme(
    brightness: scheme.brightness,
    primary: scheme.primary,
    onPrimary: scheme.onPrimary,
    primaryContainer: scheme.primaryContainer,
    onPrimaryContainer: scheme.onPrimaryContainer,
    secondary: scheme.secondary,
    onSecondary: scheme.onSecondary,
    secondaryContainer: scheme.secondaryContainer,
    onSecondaryContainer: scheme.onSecondaryContainer,
    tertiary: scheme.tertiary,
    onTertiary: scheme.onTertiary,
    tertiaryContainer: scheme.tertiaryContainer,
    onTertiaryContainer: scheme.onTertiaryContainer,
    error: scheme.error,
    onError: scheme.onError,
    errorContainer: scheme.errorContainer,
    onErrorContainer: scheme.onErrorContainer,
    surface: scheme.surface,
    onSurface: scheme.onSurface,
    onSurfaceVariant: scheme.onSurfaceVariant,
    outline: scheme.outline,
    outlineVariant: scheme.outlineVariant,
    shadow: scheme.shadow,
    scrim: scheme.scrim,
    inverseSurface: scheme.inverseSurface,
    onInverseSurface: scheme.onInverseSurface,
    inversePrimary: scheme.inversePrimary,
    surfaceTint: scheme.surfaceTint,
    surfaceDim: scheme.surfaceDim,
    surfaceBright: scheme.surfaceBright,
    surfaceContainerLowest: scheme.surfaceContainerLowest,
    surfaceContainerLow: scheme.surfaceContainerLow,
    surfaceContainer: scheme.surfaceContainer,
    surfaceContainerHigh: scheme.surfaceContainerHigh,
    surfaceContainerHighest: scheme.surfaceContainerHighest,
  );
}

/// Semantic colour roles the Material scheme does not provide: CI/issue
/// status tints and diff line tints. Status is always shown
/// as icon + label; these tints only reinforce it.
@immutable
class WorkshopColors extends ThemeExtension<WorkshopColors> {
  const WorkshopColors({
    required this.success, required this.successContainer, required this.onSuccessContainer,
    required this.running, required this.runningContainer, required this.onRunningContainer,
    required this.pending, required this.pendingContainer, required this.onPendingContainer,
    required this.neutralContainer, required this.onNeutralContainer,
    required this.diffAdded, required this.diffRemoved,
  });

  final Color success, successContainer, onSuccessContainer;
  final Color running, runningContainer, onRunningContainer;
  final Color pending, pendingContainer, onPendingContainer;
  final Color neutralContainer, onNeutralContainer;
  final Color diffAdded, diffRemoved;

  static const light = WorkshopColors(
    success: Color(0xFF1B7F3B), successContainer: Color(0xFFE3F5E8), onSuccessContainer: Color(0xFF0F4A22),
    running: Color(0xFF2457D6), runningContainer: Color(0xFFE1E8FB), onRunningContainer: Color(0xFF16337A),
    pending: Color(0xFF9A5B00), pendingContainer: Color(0xFFFFF0D6), onPendingContainer: Color(0xFF5C3600),
    neutralContainer: Color(0xFFEEF0F6), onNeutralContainer: Color(0xFF3D4452),
    diffAdded: Color(0xFF1B7F3B), diffRemoved: Color(0xFFC62828),
  );
  static const dark = WorkshopColors(
    success: Color(0xFF7DDB9A), successContainer: Color(0xFF123A22), onSuccessContainer: Color(0xFFB9F0C8),
    running: Color(0xFFA6BFFF), runningContainer: Color(0xFF1B2A55), onRunningContainer: Color(0xFFD5E0FF),
    pending: Color(0xFFFFC77A), pendingContainer: Color(0xFF3E2A08), onPendingContainer: Color(0xFFFFE2B5),
    neutralContainer: Color(0xFF262B36), onNeutralContainer: Color(0xFFC3C8D4),
    diffAdded: Color(0xFF7DDB9A), diffRemoved: Color(0xFFFF8A80),
  );

  static WorkshopColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<WorkshopColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  WorkshopColors copyWith({
    Color? success, Color? successContainer, Color? onSuccessContainer,
    Color? running, Color? runningContainer, Color? onRunningContainer,
    Color? pending, Color? pendingContainer, Color? onPendingContainer,
    Color? neutralContainer, Color? onNeutralContainer,
    Color? diffAdded, Color? diffRemoved,
  }) => WorkshopColors(
    success: success ?? this.success, successContainer: successContainer ?? this.successContainer,
    onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
    running: running ?? this.running, runningContainer: runningContainer ?? this.runningContainer,
    onRunningContainer: onRunningContainer ?? this.onRunningContainer,
    pending: pending ?? this.pending, pendingContainer: pendingContainer ?? this.pendingContainer,
    onPendingContainer: onPendingContainer ?? this.onPendingContainer,
    neutralContainer: neutralContainer ?? this.neutralContainer,
    onNeutralContainer: onNeutralContainer ?? this.onNeutralContainer,
    diffAdded: diffAdded ?? this.diffAdded, diffRemoved: diffRemoved ?? this.diffRemoved,
  );

  @override
  WorkshopColors lerp(ThemeExtension<WorkshopColors>? other, double t) {
    if (other is! WorkshopColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return WorkshopColors(
      success: mix(success, other.success), successContainer: mix(successContainer, other.successContainer),
      onSuccessContainer: mix(onSuccessContainer, other.onSuccessContainer),
      running: mix(running, other.running), runningContainer: mix(runningContainer, other.runningContainer),
      onRunningContainer: mix(onRunningContainer, other.onRunningContainer),
      pending: mix(pending, other.pending), pendingContainer: mix(pendingContainer, other.pendingContainer),
      onPendingContainer: mix(onPendingContainer, other.onPendingContainer),
      neutralContainer: mix(neutralContainer, other.neutralContainer),
      onNeutralContainer: mix(onNeutralContainer, other.onNeutralContainer),
      diffAdded: mix(diffAdded, other.diffAdded), diffRemoved: mix(diffRemoved, other.diffRemoved),
    );
  }
  List<Color> get _fields => [success, successContainer, onSuccessContainer, running, runningContainer,
    onRunningContainer, pending, pendingContainer, onPendingContainer, neutralContainer, onNeutralContainer,
    diffAdded, diffRemoved];

  @override
  bool operator ==(Object other) => other is WorkshopColors && _listEquals(_fields, other._fields);
  @override
  int get hashCode => Object.hashAll(_fields);
}

bool _listEquals(List<Color> a, List<Color> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Bundled developer monospace (JetBrains Mono, OFL) for SHAs, file contents,
/// diffs, logs and branch names. Tabular figures keep line-number gutters
/// aligned.
const codeFontFamily = 'JetBrainsMono';

/// Surfaces the bundled JetBrains Mono OFL in the license dialog. Declaring
/// the file as an asset does not put it in the SDK's generated notices.
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/JetBrainsMono-OFL.txt');
    yield LicenseEntryWithLineBreaks(const ['JetBrains Mono'], text);
  });
}

TextStyle codeTextStyle(BuildContext context, {double fontSize = 13, Color? color}) => TextStyle(
  fontFamily: codeFontFamily, fontFamilyFallback: const ['Menlo', 'monospace'],
  fontSize: fontSize, height: 1.45, color: color ?? Theme.of(context).colorScheme.onSurface,
  fontFeatures: const [FontFeature.tabularFigures()],
);

ThemeData appTheme(Brightness brightness, {ColorScheme? dynamicScheme, bool useDynamicColor = true}) {
  final dark = brightness == Brightness.dark;
  // A dynamic scheme replaces the cobalt seed. Card, outline and field fill
  // come from its surface-container and outline roles; type, shape and the
  // 48 dp controls stay the app's. Seeded dark cards are tonal content
  // containers: the fill and the press ripple identify them, so their hairline
  // stays softer than the control outline on chips, segments and outlined buttons.
  final ColorScheme scheme;
  final Color hairline, controlOutline, card, inputFill;
  if (dynamicScheme != null && useDynamicColor) {
    scheme = dynamicScheme;
    hairline = scheme.outlineVariant;
    controlOutline = scheme.outlineVariant;
    card = dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest;
    inputFill = scheme.surfaceContainerHigh;
  } else {
    scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4763E4), brightness: brightness,
      surface: dark ? const Color(0xFF15181F) : const Color(0xFFF7F8FC),
      surfaceContainerLowest: dark ? const Color(0xFF10131A) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF181C25) : const Color(0xFFF2F4F9),
      surfaceContainer: dark ? const Color(0xFF1D212B) : const Color(0xFFEDF0F6),
      surfaceContainerHigh: dark ? const Color(0xFF232833) : const Color(0xFFE6EAF2),
      surfaceContainerHighest: dark ? const Color(0xFF2A303C) : const Color(0xFFDFE3EC),
    );
    hairline = dark ? const Color(0xFF3A4050) : const Color(0xFFE5E8F0);
    // #5C6374 is 2.95:1 on #15181F. #5E6576 is the same slate, the first step
    // that clears the 3:1 non-text floor against that surface.
    controlOutline = dark ? const Color(0xFF5E6576) : const Color(0xFFE5E8F0);
    card = dark ? const Color(0xFF1F2430) : Colors.white;
    inputFill = dark ? const Color(0xFF222733) : const Color(0xFFEEF0F6);
  }
  final workshop = dark ? WorkshopColors.dark : WorkshopColors.light;
  final radius16 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  return ThemeData(
    useMaterial3: true, brightness: brightness, colorScheme: scheme,
    extensions: [workshop],
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent,
      systemOverlayStyle: systemUiOverlayStyle(brightness),
      elevation: 0, scrolledUnderElevation: 0, centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: 'Roboto', fontSize: 21, fontWeight: FontWeight.w700,
        color: scheme.onSurface, letterSpacing: -.4),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -.7),
      headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -.5),
      headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 16, height: 1.55),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, height: 1.45),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .2),
    ),
    cardTheme: CardThemeData(
      elevation: 0, color: card,
      margin: EdgeInsets.zero, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: hairline)),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      minTileHeight: 48, iconColor: scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    chipTheme: ChipThemeData(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
      secondaryLabelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
      backgroundColor: card, selectedColor: scheme.primaryContainer,
      side: BorderSide(color: controlOutline), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      showCheckmark: true, checkmarkColor: scheme.onPrimaryContainer,
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48), side: BorderSide(color: controlOutline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48))),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(
      minimumSize: const Size(48, 48), side: BorderSide(color: controlOutline),
      selectedBackgroundColor: scheme.primaryContainer, selectedForegroundColor: scheme.onPrimaryContainer,
    )),
    navigationBarTheme: NavigationBarThemeData(
      height: 72, elevation: 0, backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 12, fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      elevation: 0, backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      selectedLabelTextStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      unselectedLabelTextStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      labelType: NavigationRailLabelType.all,
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: hairline, labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant, indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent, showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent, shape: radius16,
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary, linearTrackColor: scheme.surfaceContainerHighest,
    ),
  );
}
