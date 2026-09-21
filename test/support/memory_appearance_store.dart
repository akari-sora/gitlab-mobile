import 'package:gitlab_mobile/features/shell/appearance.dart';

/// In-memory appearance store for widget and unit tests. Nothing here touches
/// the platform key store; failures are synthetic and explicitly requested.
class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.value]);
  String? value;
  bool rejectRead = false, rejectWrite = false;
  Future<void>? readDelay;
  Future<void>? writeDelay;
  final List<String?> writes = [];
  final List<String?> reads = [];
  @override
  Future<String?> read() async {
    // An in-flight read keeps the record it observed. A write that lands while
    // it is waiting must not change what this call returns.
    final snapshot = value;
    final delay = readDelay;
    if (delay != null) await delay;
    if (rejectRead) {
      throw StateError('synthetic key-store read failure');
    }
    reads.add(snapshot);
    return snapshot;
  }

  @override
  Future<void> write(String? next) async {
    final delay = writeDelay;
    if (delay != null) await delay;
    writes.add(next);
    if (rejectWrite) {
      throw StateError('synthetic key-store write failure');
    }
    value = next;
  }
}
