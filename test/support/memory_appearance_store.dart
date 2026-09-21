import 'package:gitlab_mobile/features/shell/appearance.dart';

/// In-memory appearance store for widget and unit tests. Nothing here touches
/// the platform key store; failures are synthetic and explicitly requested.
class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.value]);
  String? value;
  bool rejectRead = false, rejectWrite = false;
  final List<String?> writes = [];
  @override
  Future<String?> read() async {
    if (rejectRead) {
      throw StateError('synthetic key-store read failure');
    }
    return value;
  }

  @override
  Future<void> write(String? next) async {
    writes.add(next);
    if (rejectWrite) {
      throw StateError('synthetic key-store write failure');
    }
    value = next;
  }
}
