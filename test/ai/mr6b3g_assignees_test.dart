import 'package:flutter_test/flutter_test.dart';

// The family owner replaces this empty stage with the complete fixed set.
const groupAssigneesStageOperations = <String>{};

void main() {
  test('group assignees stage is initially empty', () {
    expect(groupAssigneesStageOperations, isEmpty);
  });
}
