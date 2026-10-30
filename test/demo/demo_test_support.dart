import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';

/// Backs the secure-storage test platform and records every change, so a
/// write that is deleted again still counts.
final class RecordingSecureValues extends MapBase<String, String> {
  final Map<String, String> _values = {};
  final List<String> changes = [];

  @override
  String? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, String value) {
    changes.add('write $key');
    _values[key] = value;
  }

  @override
  void clear() {
    changes.add('clear');
    _values.clear();
  }

  @override
  Iterable<String> get keys => _values.keys;

  @override
  String? remove(Object? key) {
    changes.add('delete $key');
    return _values.remove(key);
  }
}

/// Installs a recording secure-storage platform for the current test.
RecordingSecureValues recordSecureStorage() {
  final values = RecordingSecureValues();
  FlutterSecureStorage.setMockInitialValues(values);
  return values;
}

/// No path_provider, no package_info: a test that reaches them fails loudly.
Future<BuildInfo> testBuildInfo() async =>
    const BuildInfo(version: '0.0.0', buildNumber: '1', commit: 'test');

/// Any `HttpClient` the code under test opens is counted and refused, so a
/// caller that swallows the error still shows up in [NoNetwork.attempts].
HttpOverrides get noNetwork => NoNetwork();

final class NoNetwork extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('The demo opened a real HTTP connection');
  }
}

void phoneView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
