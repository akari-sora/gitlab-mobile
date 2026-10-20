import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../l10n/l10n.dart';

/// The language choice is a device preference like the appearance: shared by
/// every account and kept across account switches.
abstract interface class LanguageStore {
  Future<String?> read();
  Future<void> write(String? tag);
}

/// One secure-storage key holding the picked language tag and the device's
/// languages at the time (`ja|en-US,fr-FR`, see [encodeLanguageChoice]); no key
/// means the app follows the device's languages.
final class SecureLanguageStore implements LanguageStore {
  SecureLanguageStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage _storage;
  static const key = 'gitlab_mobile_language_v1';
  @override
  Future<String?> read() => _storage.read(key: key);
  @override
  Future<void> write(String? tag) => tag == null
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: tag);
}

/// The Flutter locale for [language], as given to `MaterialApp.locale`.
Locale localeOf(AppLanguage language) => Locale.fromSubtags(
  languageCode: language.languageCode,
  scriptCode: language.scriptCode,
  countryCode: language.countryCode,
);

/// Every language as a Flutter locale, for `MaterialApp.supportedLocales`.
final List<Locale> appLocales = [for (final language in appLanguages) localeOf(language)];

/// Holds the app's language and keeps [l10n] on it. Until the user picks one
/// ([choice] is null) the app follows the device's languages, English when
/// none of them is translated. The most recent change wins: a pick in the app
/// holds until the device's language (or the system's per-app language on
/// Android 13+ and iOS) changes, and then the app follows the device again.
class LanguageController extends ChangeNotifier with WidgetsBindingObserver {
  LanguageController(this._store, {List<Locale> Function()? deviceLocales})
    : _deviceLocales = deviceLocales ?? (() => WidgetsBinding.instance.platformDispatcher.locales) {
    _device = _deviceTag();
    _language = _resolve();
  }
  final LanguageStore _store;
  final List<Locale> Function() _deviceLocales;
  late AppLanguage _language;
  String? _choice;

  /// The device's language list when [_choice] was made.
  String? _choiceDevice;

  /// The device's language list as last seen.
  String? _device;
  bool _loaded = false;
  bool _observing = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _writes;

  AppLanguage get language => _language;
  Locale get locale => localeOf(_language);

  /// The picked language's tag, or null while following the device.
  String? get choice => _choice;
  bool get loaded => _loaded;

  /// Reads the stored choice and applies it. An unreadable or unknown value
  /// follows the device, and so does a choice made while the device had
  /// another language. The device's language applies to [l10n] at once, so
  /// text and layout agree even if the read is slow; a read that finishes
  /// late still applies a stored choice unless the user picked or the
  /// device's languages changed meanwhile.
  Future<void> load() async {
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _device = _deviceTag();
    _language = _resolve();
    useLanguage(_language);
    final generation = _generation;
    String? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      stored = null;
    }
    if (_disposed) return;
    _loaded = true;
    // A pick or a device language change during the read supersedes it.
    if (generation == _generation) {
      final (tag, device) = decodeLanguageChoice(stored);
      final valid = languageForTag(tag) != null;
      if (valid && (device == null || device == _device)) {
        _choice = tag;
        _choiceDevice = device ?? _device;
        // A value without the device's languages is completed, so a later
        // change can be recognised.
        if (device == null) unawaited(_enqueueWrite(encodeLanguageChoice(tag!, _choiceDevice)));
      } else {
        _choice = _choiceDevice = null;
        if (stored != null) unawaited(_enqueueWrite(null));
      }
    }
    _apply(force: true);
  }

  /// Picks [tag], or follows the device again when it is null.
  Future<void> select(String? tag) {
    if (tag != null && languageForTag(tag) == null) return Future<void>.value();
    _generation++;
    final changed = tag != _choice;
    _choice = tag;
    _choiceDevice = tag == null ? null : _device;
    _apply(force: changed);
    return _enqueueWrite(tag == null ? null : encodeLanguageChoice(tag, _choiceDevice));
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    final device = _deviceTag();
    // Android re-sends the locales on other configuration changes.
    if (device == _device) return;
    _device = device;
    _generation++;
    if (_choice != null && device != _choiceDevice) {
      // The device (or the system's per-app setting) moved on after the pick.
      _choice = _choiceDevice = null;
      unawaited(_enqueueWrite(null));
      _apply(force: true);
      return;
    }
    _apply();
  }

  /// The device's ordered language list, which decides the language when the
  /// app follows the device.
  String? _deviceTag() {
    final locales = _deviceLocales();
    return locales.isEmpty ? null : locales.map((locale) => locale.toLanguageTag()).join(',');
  }

  // Writes run one after another, so the stored value is always the last one
  // asked for.
  Future<void> _enqueueWrite(String? value) {
    final next = (_writes ?? Future<void>.value()).then((_) => _store.write(value)).catchError((Object _) {
      // The choice still holds for this run; it is simply not remembered.
    });
    _writes = next;
    return next;
  }

  AppLanguage _resolve() {
    final picked = languageForTag(_choice);
    if (picked != null) return picked;
    return resolveLanguage([
      for (final locale in _deviceLocales())
        (languageCode: locale.languageCode, scriptCode: locale.scriptCode, countryCode: locale.countryCode),
    ]);
  }

  void _apply({bool force = false}) {
    if (_disposed) return;
    final next = _resolve();
    final changed = !identical(next, _language);
    _language = next;
    useLanguage(next);
    if (changed || force) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// The stored value: `<tag>|<device language tags when picked, comma-separated>`.
/// A bare tag carries no device languages.
String encodeLanguageChoice(String tag, String? device) => device == null ? tag : '$tag|$device';

(String?, String?) decodeLanguageChoice(String? value) {
  if (value == null || value.isEmpty) return (null, null);
  final split = value.indexOf('|');
  if (split < 0) return (value, null);
  final device = value.substring(split + 1);
  return (value.substring(0, split), device.isEmpty ? null : device);
}

/// Rebuilds every element under [context] so text read from [l10n] during a
/// build picks up a new language while state (routes, scroll positions,
/// drafts) is kept.
void rebuildForLanguage(BuildContext context) {
  void mark(Element element) {
    element.markNeedsBuild();
    element.visitChildren(mark);
  }

  (context as Element).visitChildren(mark);
}
