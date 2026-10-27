import 'package:flutter_test/flutter_test.dart';

// The family owner replaces this empty stage with the complete fixed set.
const groupSnoozeStageOperations = <String>{};

void main() {
  test('group snooze stage is initially empty', () {
    expect(groupSnoozeStageOperations, isEmpty);
  });
}
