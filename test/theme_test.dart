import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final light = la > lb ? la : lb, darkL = la > lb ? lb : la;
  return (light + 0.05) / (darkL + 0.05);
}

void main() {
  test('appTheme without a dynamic scheme uses the GitHub-style palette', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      final palette = AppPalette.of(brightness);
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
      expect(theme.colorScheme.primary, palette.accent);
      expect(theme.colorScheme.onPrimary, palette.onAccent);
      expect(theme.colorScheme.surface, palette.surface);
      expect(theme.colorScheme.onSurface, palette.text);
      expect(theme.colorScheme.onSurfaceVariant, palette.muted);
      expect(theme.colorScheme.primaryContainer, palette.accentContainer);
      expect(theme.scaffoldBackgroundColor, palette.canvas);
      expect(theme.appBarTheme.backgroundColor, palette.surface);
      expect(theme.navigationBarTheme.backgroundColor, palette.surface);
      expect(theme.navigationBarTheme.indicatorColor, palette.accentContainer);
      expect(ignored.colorScheme.primary, theme.colorScheme.primary);
      expect(ignored.cardTheme.color, theme.cardTheme.color);
      expect(theme.cardTheme.color, palette.surface);
      expect(theme.inputDecorationTheme.fillColor, palette.raised);
      expect(theme.chipTheme.backgroundColor, palette.chip);
      expect(theme.chipTheme.shape, isA<StadiumBorder>());
      final side = (theme.cardTheme.shape! as RoundedRectangleBorder).side;
      expect(side.color, palette.hairline);
      expect(theme.outlinedButtonTheme.style!.side!.resolve({})!.color, palette.control);
      expect(theme.segmentedButtonTheme.style!.side!.resolve({})!.color, palette.control);
      // Text and the accent stay readable on the raised surface and canvas.
      for (final background in [palette.surface, palette.canvas]) {
        expect(_contrast(palette.text, background), greaterThanOrEqualTo(7));
        expect(_contrast(palette.muted, background), greaterThanOrEqualTo(4.5));
        expect(_contrast(palette.accent, background), greaterThanOrEqualTo(4.5));
      }
      expect(_contrast(palette.onAccent, palette.accent), greaterThanOrEqualTo(4.5));
      expect(_contrast(palette.onAccentContainer, palette.accentContainer), greaterThanOrEqualTo(4.5));
      if (dark) {
        expect(_contrast(palette.control, theme.colorScheme.surface), greaterThanOrEqualTo(3));
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
    expect((darkTheme.cardTheme.shape! as RoundedRectangleBorder).side.color, dynamicDark.outlineVariant);
    expect(darkTheme.scaffoldBackgroundColor, dynamicDark.surface);
  });

  test('page transitions fade over the canvas, not a lighter surface', () {
    final dynamic = ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32));
    for (final theme in [appTheme(Brightness.light), appTheme(Brightness.dark), appTheme(Brightness.light, dynamicScheme: dynamic)]) {
      final android = theme.pageTransitionsTheme.builders[TargetPlatform.android];
      expect(android, isA<PredictiveBackPageTransitionsBuilder>());
      expect((android! as PredictiveBackPageTransitionsBuilder).fallbackColor, theme.scaffoldBackgroundColor);
      expect(theme.pageTransitionsTheme.builders[TargetPlatform.iOS], isNotNull);
    }
  });

  test('registerBundledLicenses yields the JetBrains Mono OFL', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerBundledLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    final mono = entries.where((entry) => entry.packages.contains('JetBrains Mono'));
    expect(mono, isNotEmpty);
    final text = mono.first.paragraphs.map((paragraph) => paragraph.text).join('\n');
    expect(text, contains('SIL Open Font License'));
  });
}
