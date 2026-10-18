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

  // Primer-style status hues: green success, blue running, amber pending.
  static const light = WorkshopColors(
    success: Color(0xFF1A7F37), successContainer: Color(0xFFDAFBE1), onSuccessContainer: Color(0xFF044F1E),
    running: Color(0xFF0969DA), runningContainer: Color(0xFFDDF4FF), onRunningContainer: Color(0xFF0A3069),
    pending: Color(0xFF9A6700), pendingContainer: Color(0xFFFFF8C5), onPendingContainer: Color(0xFF4D2D00),
    neutralContainer: Color(0xFFEFF2F5), onNeutralContainer: Color(0xFF424A53),
    diffAdded: Color(0xFF1A7F37), diffRemoved: Color(0xFFCF222E),
  );
  static const dark = WorkshopColors(
    success: Color(0xFF3FB950), successContainer: Color(0xFF0F2A1A), onSuccessContainer: Color(0xFFA6EBB6),
    running: Color(0xFF58A6FF), runningContainer: Color(0xFF14273F), onRunningContainer: Color(0xFFC2DCFF),
    pending: Color(0xFFD29922), pendingContainer: Color(0xFF33260A), onPendingContainer: Color(0xFFF2D18A),
    neutralContainer: Color(0xFF26272D), onNeutralContainer: Color(0xFFC5C8CF),
    diffAdded: Color(0xFF3FB950), diffRemoved: Color(0xFFFF7B72),
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

/// Neutral palette modelled on GitHub Mobile: a near-black (or soft grey)
/// canvas, one raised surface for bars, sections and cards, a single blue
/// accent and hairline dividers. Status keeps its own [WorkshopColors].
@immutable
class AppPalette {
  const AppPalette({
    required this.canvas, required this.surface, required this.raised, required this.chip,
    required this.hairline, required this.control, required this.text, required this.muted,
    required this.accent, required this.onAccent, required this.accentContainer, required this.onAccentContainer,
    required this.selection, required this.onSelection,
    required this.danger, required this.onDanger, required this.dangerContainer, required this.onDangerContainer,
  });

  /// Page background behind sections and lists.
  final Color canvas;
  /// App bars, bottom navigation, grouped sections and cards.
  final Color surface;
  /// Search fields and secondary buttons sitting on [surface].
  final Color raised;
  /// Filter chips.
  final Color chip;
  final Color hairline, control, text, muted;
  final Color accent, onAccent, accentContainer, onAccentContainer;
  final Color selection, onSelection;
  final Color danger, onDanger, dangerContainer, onDangerContainer;

  static const dark = AppPalette(
    canvas: Color(0xFF08090B), surface: Color(0xFF17181C), raised: Color(0xFF212227), chip: Color(0xFF2F2F37),
    hairline: Color(0xFF2E2F34), control: Color(0xFF5E6576), text: Color(0xFFF0F1F3), muted: Color(0xFF9195A0),
    accent: Color(0xFF58A6FF), onAccent: Color(0xFF051D39),
    accentContainer: Color(0xFF1A2B3F), onAccentContainer: Color(0xFFB6D7FF),
    selection: Color(0xFF1C2D44), onSelection: Color(0xFFD3E6FF),
    danger: Color(0xFFFF7B72), onDanger: Color(0xFF3D0905),
    dangerContainer: Color(0xFF3B1418), onDangerContainer: Color(0xFFFFC4BF),
  );
  static const light = AppPalette(
    canvas: Color(0xFFF2F4F7), surface: Colors.white, raised: Color(0xFFEFF2F5), chip: Color(0xFFE9EDF1),
    hairline: Color(0xFFD8DEE4), control: Color(0xFFC3CBD4), text: Color(0xFF1F2328), muted: Color(0xFF59636E),
    accent: Color(0xFF0969DA), onAccent: Colors.white,
    accentContainer: Color(0xFFDDF4FF), onAccentContainer: Color(0xFF0A3069),
    selection: Color(0xFFE5F0FC), onSelection: Color(0xFF0A3069),
    danger: Color(0xFFCF222E), onDanger: Colors.white,
    dangerContainer: Color(0xFFFFEBE9), onDangerContainer: Color(0xFF82071E),
  );

  static AppPalette of(Brightness brightness) => brightness == Brightness.dark ? dark : light;
}

ThemeData appTheme(Brightness brightness, {ColorScheme? dynamicScheme, bool useDynamicColor = true}) {
  final dark = brightness == Brightness.dark;
  // A dynamic scheme replaces the GitHub-style palette. Card, outline and field
  // fill come from its surface-container and outline roles; type, shape and the
  // 48 dp controls stay the app's.
  final ColorScheme scheme;
  final Color hairline, controlOutline, card, inputFill, canvas, chipFill;
  if (dynamicScheme != null && useDynamicColor) {
    scheme = dynamicScheme;
    hairline = scheme.outlineVariant;
    controlOutline = scheme.outlineVariant;
    card = dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest;
    inputFill = scheme.surfaceContainerHigh;
    canvas = scheme.surface;
    chipFill = scheme.surfaceContainerHigh;
  } else {
    final palette = AppPalette.of(brightness);
    scheme = ColorScheme.fromSeed(
      seedColor: palette.accent, brightness: brightness,
      primary: palette.accent, onPrimary: palette.onAccent,
      primaryContainer: palette.accentContainer, onPrimaryContainer: palette.onAccentContainer,
      secondaryContainer: palette.selection, onSecondaryContainer: palette.onSelection,
      error: palette.danger, onError: palette.onDanger,
      errorContainer: palette.dangerContainer, onErrorContainer: palette.onDangerContainer,
      surface: palette.surface, onSurface: palette.text, onSurfaceVariant: palette.muted,
      surfaceContainerLowest: palette.canvas,
      surfaceContainerLow: dark ? const Color(0xFF1B1C21) : const Color(0xFFF6F8FA),
      surfaceContainer: palette.raised,
      surfaceContainerHigh: dark ? const Color(0xFF26272D) : const Color(0xFFE6EAEF),
      surfaceContainerHighest: palette.chip,
      outline: palette.control, outlineVariant: palette.hairline,
    );
    hairline = palette.hairline;
    // #5E6576 clears the 3:1 non-text floor against the dark surface #17181C.
    controlOutline = palette.control;
    card = palette.surface;
    inputFill = palette.raised;
    canvas = palette.canvas;
    chipFill = palette.chip;
  }
  final workshop = dark ? WorkshopColors.dark : WorkshopColors.light;
  final radius12 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  final theme = ThemeData(
    useMaterial3: true, brightness: brightness, colorScheme: scheme,
    extensions: [workshop],
    scaffoldBackgroundColor: canvas,
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: hairline)),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      minTileHeight: 48, iconColor: scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    chipTheme: ChipThemeData(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      backgroundColor: chipFill, selectedColor: scheme.primaryContainer,
      // Filled pills: the outline only appears where the fill alone would not
      // separate the chip from the surface (dynamic schemes).
      side: BorderSide(color: controlOutline, width: 0, style: BorderStyle.none),
      shape: const StadiumBorder(),
      showCheckmark: true, checkmarkColor: scheme.onPrimaryContainer,
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48), side: BorderSide(color: controlOutline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(size: 24,
        color: states.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant)),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 12, color: scheme.onSurface,
        fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      elevation: 0, backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: const StadiumBorder(),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurface),
      unselectedLabelTextStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
      labelType: NavigationRailLabelType.all,
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: hairline, labelColor: scheme.onSurface, indicatorColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant, indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? scheme.surfaceContainerLow : scheme.surface,
      surfaceTintColor: Colors.transparent, showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? scheme.surfaceContainerLow : scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? scheme.surfaceContainerHigh : scheme.surface,
      surfaceTintColor: Colors.transparent, shape: radius12,
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary, linearTrackColor: scheme.surfaceContainerHighest,
    ),
  );
  // Chip labels start from the resolved type scale so they keep the
  // platform font family like every other label.
  final label = theme.textTheme.labelLarge!;
  return theme.copyWith(chipTheme: theme.chipTheme.copyWith(
    labelStyle: label.copyWith(fontSize: 14, fontWeight: FontWeight.w500, color: scheme.onSurface),
    secondaryLabelStyle: label.copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onPrimaryContainer),
  ));
}
