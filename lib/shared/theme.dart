import 'package:flutter/material.dart';

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1E55A6), brightness: brightness,
    primary: dark ? const Color(0xFF9BC2FF) : const Color(0xFF1E55A6),
    surface: dark ? const Color(0xFF1B2230) : Colors.white,
  );
  return ThemeData(
    useMaterial3: true, colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF141820) : const Color(0xFFF7F8FA),
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48))),
    textTheme: const TextTheme(bodyLarge: TextStyle(fontSize: 16), bodyMedium: TextStyle(fontSize: 16)),
    appBarTheme: const AppBarTheme(centerTitle: false),
  );
}
