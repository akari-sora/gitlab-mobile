import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/picker_sheet.dart';

void main() {
  const labels = [EditField.picker('labels', '標籤', source: PickerSource.labels, multi: true)];
  const branch = [EditField.picker('source_branch', '來源分支', source: PickerSource.branches)];
  const members = [EditField.picker('assignee_ids', '指派', source: PickerSource.members, multi: true)];

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

  test('envelope and bare choice lists restore labels, members and branches', () {
    final envelope = encodeChoices(const [PickerChoice(id: 'a', name: 'a', color: '#d9534f')]);
    expect(jsonDecode(envelope), containsPair('picker', 1));
    expect(decodeChoices(envelope, source: PickerSource.labels).single.color, '#d9534f');
    expect(editorSubmission(labels, {'labels': envelope})['labels'], 'a');

    const bareLabels = '[{"id":"a","name":"a","color":"#d9534f"},{"id":"b","name":"b"}]';
    final decodedLabels = decodeChoices(bareLabels, source: PickerSource.labels);
    expect(decodedLabels.map((choice) => choice.name), ['a', 'b']);
    expect(decodedLabels.first.color, '#d9534f');
    expect(editorSubmission(labels, {'labels': bareLabels})['labels'], 'a, b');

    const bareMembers = '[{"id":"8","name":"Reviewer","username":"reviewer"}]';
    final member = decodeChoices(bareMembers, source: PickerSource.members).single;
    expect(member.id, '8');
    expect(member.username, 'reviewer');
    expect(editorSubmission(members, {'assignee_ids': bareMembers})['assignee_ids'], [8]);

    const bareBranch = '[{"id":"feature/navigation","name":"feature/navigation"}]';
    expect(decodeChoices(bareBranch, source: PickerSource.branches).single.name, 'feature/navigation');
    expect(editorSubmission(branch, {'source_branch': bareBranch})['source_branch'], 'feature/navigation');

    const commaBranch = '[{"id":"release,a","name":"release,a"}]';
    expect(decodeChoices(commaBranch, source: PickerSource.branches).map((choice) => choice.name), ['release,a']);
    expect(editorSubmission(branch, {'source_branch': commaBranch})['source_branch'], 'release,a');

    expect(decodeChoices('[]', source: PickerSource.labels), isEmpty);
    expect(editorSubmission(labels, {'labels': '[]'})['labels'], '');
    expect(decodeChoices('[1,2]', source: PickerSource.branches).single.name, '[1,2]');
  });
}
