import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/theme.dart';

void main() {
  test('appTheme without a dynamic scheme keeps the seeded cobalt theme', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      final seeded = ColorScheme.fromSeed(
        seedColor: const Color(0xFF4763E4),
        brightness: brightness,
        surface: dark ? const Color(0xFF15181F) : const Color(0xFFF7F8FC),
      );
      final theme = appTheme(brightness);
      final supplied = ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D32),
        brightness: brightness,
      );
      final ignored = appTheme(
        brightness,
        dynamicScheme: supplied,
        useDynamicColor: false,
      );
      expect(theme.colorScheme.primary, seeded.primary);
      expect(theme.colorScheme.surface, seeded.surface);
      expect(ignored.colorScheme.primary, theme.colorScheme.primary);
      expect(ignored.cardTheme.color, theme.cardTheme.color);
      expect(theme.cardTheme.color, dark ? const Color(0xFF1D212B) : Colors.white);
      expect(
        theme.inputDecorationTheme.fillColor,
        dark ? const Color(0xFF222733) : const Color(0xFFEEF0F6),
      );
      // Dark cards rely on tonal difference alone; light cards keep a hairline.
      final side = (theme.cardTheme.shape! as RoundedRectangleBorder).side;
      if (dark) {
        expect(side.style, BorderStyle.none);
      } else {
        expect(side.color, const Color(0xFFE5E8F0));
      }
      expect(theme.filledButtonTheme.style!.minimumSize!.resolve({}), const Size(48, 48));
      expect(theme.textTheme.titleLarge!.fontSize, 19);
      final overlay = theme.appBarTheme.systemOverlayStyle!;
      final icons = dark ? Brightness.light : Brightness.dark;
      expect(overlay.statusBarIconBrightness, icons);
      expect(overlay.systemNavigationBarIconBrightness, icons);
      expect(overlay.statusBarColor, Colors.transparent);
      expect(overlay.systemNavigationBarColor, Colors.transparent);
      expect(overlay.systemNavigationBarContrastEnforced, isFalse);
      expect(overlay.systemStatusBarContrastEnforced, isFalse);
      expect(overlay, systemUiOverlayStyle(brightness));
    }
  });

  test('appTheme with a dynamic scheme uses its primary and container roles', () {
    final dynamicLight = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB00020),
      brightness: Brightness.light,
    );
    final theme = appTheme(Brightness.light, dynamicScheme: dynamicLight);
    expect(theme.colorScheme.primary, dynamicLight.primary);
    expect(theme.colorScheme.primary, isNot(appTheme(Brightness.light).colorScheme.primary));
    expect(theme.cardTheme.color, dynamicLight.surfaceContainerLowest);
    expect(
      (theme.cardTheme.shape! as RoundedRectangleBorder).side.color,
      dynamicLight.outlineVariant,
    );
    expect(theme.inputDecorationTheme.fillColor, dynamicLight.surfaceContainerHigh);
    expect(theme.filledButtonTheme.style!.minimumSize!.resolve({}), const Size(48, 48));
    expect(theme.iconButtonTheme.style!.minimumSize!.resolve({}), const Size(48, 48));

    final dynamicDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB00020),
      brightness: Brightness.dark,
    );
    final darkTheme = appTheme(Brightness.dark, dynamicScheme: dynamicDark);
    expect(darkTheme.colorScheme.primary, dynamicDark.primary);
    expect(darkTheme.cardTheme.color, dynamicDark.surfaceContainerHigh);
    expect(darkTheme.inputDecorationTheme.fillColor, dynamicDark.surfaceContainerHigh);
    expect((darkTheme.cardTheme.shape! as RoundedRectangleBorder).side.style, BorderStyle.none);
    expect(darkTheme.scaffoldBackgroundColor, dynamicDark.surface);
  });
}
