import 'package:flutter/material.dart';

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4763E4), brightness: brightness,
    surface: dark ? const Color(0xFF15181F) : const Color(0xFFF7F8FC),
  );
  final outline = dark ? const Color(0xFF303540) : const Color(0xFFE5E8F0);
  return ThemeData(
    useMaterial3: true, brightness: brightness, colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent,
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
    ),
    cardTheme: CardThemeData(
      elevation: 0, color: dark ? const Color(0xFF1D212B) : Colors.white,
      margin: EdgeInsets.zero, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: outline)),
    ),
    dividerTheme: DividerThemeData(color: outline, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: dark ? const Color(0xFF222733) : const Color(0xFFEEF0F6),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48), side: BorderSide(color: outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48))),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    navigationBarTheme: NavigationBarThemeData(
      height: 72, elevation: 0, backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontSize: 12, fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500)),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: outline, labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant, indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
  );
}
