import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/picker_sheet.dart';

void main() {
  const labels = [EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true)];
  const branch = [EditField.picker('source_branch', '來源分支', source: PickerSource.branches)];

  test('legacy json scalars stay label text and submit unchanged', () {
    for (final raw in ['1', '123', 'true', 'null']) {
      expect(decodeChoices(raw, source: PickerSource.labels).map((choice) => choice.name), [raw]);
      expect(editorSubmission(labels, {'labels': raw})['labels'], raw);
    }
  });

  test('legacy branch name with a comma is not split', () {
    expect(decodeChoices('release,a', source: PickerSource.branches).single.name, 'release,a');
    expect(editorSubmission(branch, {'source_branch': 'release,a'})['source_branch'], 'release,a');
  });

  test('only a picker envelope is structured choice data', () {
    final encoded = encodeChoices(const [PickerChoice(id: 'a', name: 'a', color: '#d9534f')]);
    expect(jsonDecode(encoded), containsPair('picker', 1));
    expect(decodeChoices(encoded, source: PickerSource.labels).single.color, '#d9534f');
    const array = '[{"id":"a","name":"a"}]';
    expect(decodeChoices(array, source: PickerSource.branches).single.name, array);
  });
}
