import '../l10n/l10n.dart';

/// The app's name in the UI and on the store listing. It leaves "GitLab" out
/// of the name, as GitLab's trademark guidelines and Play's impersonation
/// policy expect of an independent client; GitLab is named only to say what
/// the app works with.
const appName = 'Mergeline';

/// Shown wherever the app describes itself, as GitLab's guidelines ask of a
/// third party naming the product it works with.
String get appIndependence => l10n.independentClientDisclaimer;
