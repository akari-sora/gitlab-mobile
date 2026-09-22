import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/attachment_ref.dart';

ProjectUploadRef _ref(String name) =>
    ProjectUploadRef(secret: '0123456789abcdef0123456789abcdef', filename: name);

void main() {
  test('a reference keeps its slot across repeated claims', () {
    final budget = AttachmentBudget(maxImages: 2);
    expect(budget.claimImage(_ref('a.png')), isTrue);
    expect(budget.claimImage(_ref('a.png')), isTrue);
    expect(budget.claimImage(_ref('b.png')), isTrue);
    expect(budget.claimImage(_ref('c.png')), isFalse);
    expect(budget.claimImage(_ref('a.png')), isTrue);
  });

  test('a payload that does not fit is dropped without being charged', () async {
    final budget = AttachmentBudget(maxTotalBytes: 10);
    expect(await budget.fetch(_ref('a.png'), () async => Uint8List(8)), hasLength(8));
    await expectLater(
      budget.fetch(_ref('b.png'), () async => Uint8List(5)),
      throwsA(isA<AttachmentBudgetExceeded>()),
    );
    // 8 bytes are held; the dropped 5 were never counted, so 2 more fit.
    expect(await budget.fetch(_ref('c.png'), () async => Uint8List(2)), hasLength(2));
    await expectLater(
      budget.fetch(_ref('d.png'), () async => Uint8List(1)),
      throwsA(isA<AttachmentBudgetExceeded>()),
    );
  });
}
