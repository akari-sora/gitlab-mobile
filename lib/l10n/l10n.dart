import 'strings.g.dart';

export 'strings.g.dart';

/// The language the app is written in; it is also every test's language.
final AppLanguage sourceLanguage = appLanguages.first;

AppStrings _current = AppStrings(sourceLanguage);

/// The current language's messages. Plain Dart, so `lib/core` can use it.
/// The widget tree is rebuilt from its root when the language changes, so a
/// string read here during a build is always current.
AppStrings get l10n => _current;

/// Text from GitLab (a name, title, path or reference such as `!44`) for a
/// widget of its own. In a right-to-left language it is isolated, so it keeps
/// its own direction: `!44` stays `!44` and `@user` stays `@user`. Values put
/// into translated messages are isolated by the messages themselves.
String isolated(String text) => _current.language.rtl ? bidiIsolated(text) : text;

/// Switches every later lookup to [language].
void useLanguage(AppLanguage language) {
  if (!identical(_current.language, language)) _current = AppStrings(language);
}

AppLanguage? languageForTag(String? tag) {
  for (final language in appLanguages) {
    if (language.tag == tag) return language;
  }
  return null;
}

/// The best supported language for one of the device's locales, or null.
/// Chinese follows the script (Taiwan, Hong Kong and Macau write Traditional
/// characters); Portuguese, Spanish and the rest match on the language.
AppLanguage? matchLanguage(String languageCode, {String? scriptCode, String? countryCode}) {
  if (languageCode == 'zh') {
    final traditional = scriptCode == 'Hant' ||
        (scriptCode == null && const {'TW', 'HK', 'MO'}.contains(countryCode));
    return languageForTag(traditional ? 'zh-TW' : 'zh-CN');
  }
  // Indonesian is still reported as the obsolete "in" by some devices.
  final code = languageCode == 'in' ? 'id' : languageCode;
  for (final language in appLanguages) {
    if (language.languageCode == code) return language;
  }
  return null;
}

/// The language for the device's preferred locales: the first one supported,
/// English when none is.
AppLanguage resolveLanguage(Iterable<({String languageCode, String? scriptCode, String? countryCode})> preferred) {
  for (final locale in preferred) {
    final match = matchLanguage(locale.languageCode, scriptCode: locale.scriptCode, countryCode: locale.countryCode);
    if (match != null) return match;
  }
  return languageForTag('en')!;
}
