import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

/// Tests read the app in the language it is written in, Traditional Chinese,
/// whatever the host's locale is or an earlier test switched to.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => useLanguage(sourceLanguage));
  await testMain();
}
