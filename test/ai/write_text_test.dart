import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/group_work_item_identity.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/shared/attachment_ref.dart';

const _secret = '0123456789abcdef0123456789abcdef';
const _otherSecret = 'fedcba9876543210fedcba9876543210';
const _token = 'glpat-abcdefghijklmnopqrst';

void main() {
  test('upload IDs never alias leading zero or over-long spellings', () {
    final table = _table();
    final field = _field(AiWritableField.issueDescription);
    const original = '![a](/uploads/$_secret/a.png)';
    final outgoing = table.redactOutgoing(original, field: field);
    expect(outgoing, '![a]([[upload:u-1]])');
    expect(table.restoreIntoSameField(outgoing, field).finalText, original);
    expect(
      _prepare(
        modelText: outgoing,
        field: field,
        placeholders: table,
      ).finalText,
      original,
    );
    for (final id in ['01', '001', '9' * 200]) {
      final alias = '![a]([[upload:u-$id]])';
      expect(
        table.restoreIntoSameField(alias, field).blockedReasonCode,
        AiTextBlockCode.rereadField,
        reason: id,
      );
      expect(
        _prepare(
          modelText: alias,
          field: field,
          placeholders: table,
        ).blockedReasonCode,
        AiTextBlockCode.rereadField,
        reason: id,
      );
    }
  });

  for (final groupOwned in [false, true]) {
    group('G0j ${groupOwned ? 'group' : 'project'} title guard', () {
      AiFieldProvenance title({bool complete = true}) {
        final source = groupOwned
            ? _groupField(_groupIdentity())
            : _field(AiWritableField.issueDescription);
        return AiFieldProvenance(
          resourceKey: source.resourceKey,
          fieldName: 'title',
          completeValue: complete,
          resourceWeb: source.resourceWeb,
          accountKey: source.accountKey,
          projectId: source.projectId,
          projectFullPath: source.projectFullPath,
          groupId: source.groupId,
          groupFullPath: source.groupFullPath,
        );
      }

      UploadPlaceholderTable table() =>
          groupOwned ? _groupTable(_groupIdentity()) : _table();

      test('whole titles edit; excerpts and later cuts refuse', () {
        final placeholders = table();
        final field = title();
        AiTextOutcome prepare(AiFieldProvenance provenance) => _prepare(
          textClass: AiTextClass.plainContent,
          modelText: 'Changed title',
          field: provenance,
          placeholders: placeholders,
        );
        expect(prepare(field).finalText, 'Changed title');
        expect(
          prepare(title(complete: false)).blockedReasonCode,
          AiTextBlockCode.fieldTooLong,
        );
        placeholders.recordFieldDelivery(field, whole: true);
        placeholders.markWholeFieldsCut();
        expect(prepare(field).blockedReasonCode, AiTextBlockCode.fieldTooLong);
      });

      test('title uploads never mint or restore tokens', () {
        final placeholders = table();
        final field = title();
        const original = '[file](/uploads/$_secret/a.txt)';
        final outgoing = placeholders.redactOutgoing(original, field: field);
        expect(outgoing, isNot(contains('[[upload:')));
        expect(outgoing, isNot(contains(_secret)));
        expect(placeholders.length, 0);
        final description = groupOwned
            ? _groupField(_groupIdentity())
            : _field(AiWritableField.issueDescription);
        final masked = placeholders.redactOutgoing(
          original,
          field: description,
        );
        expect(masked, contains('[[upload:'));
        final result = _prepare(
          textClass: AiTextClass.plainContent,
          modelText: masked,
          field: field,
          placeholders: placeholders,
        );
        expect(result.blockedReasonCode, AiTextBlockCode.rereadField);
        expect(result.finalText, isNull);
      });
    });
  }

  group('G0a group field provenance', () {
    test('public provenance cannot mint or restore a verified group token', () {
      final identity = _groupIdentity();
      final field = _groupField(identity);
      const original = '![a](/uploads/$_secret/a.png)';
      final table = _groupTable(identity);
      final outgoing = table.redactOutgoing(original, field: field);
      expect(table.restoreIntoSameField(outgoing, field).finalText, original);
      for (final groupId in [field.groupId, null]) {
        for (final path in [field.groupFullPath, null]) {
          for (final account in [field.accountKey, null]) {
            final forged = AiFieldProvenance(
              resourceKey: field.resourceKey,
              fieldName: field.fieldName,
              completeValue: true,
              resourceWeb: field.resourceWeb,
              groupId: groupId,
              groupFullPath: path,
              accountKey: account,
            );
            if (groupId != null || path != null || account != null) {
              final emptyTable = _groupTable(identity);
              expect(
                emptyTable.redactOutgoing(original, field: forged),
                isNot(contains('[[upload:')),
              );
              expect(emptyTable.length, 0);
            }
            expect(
              table.restoreIntoSameField(outgoing, forged).blockedReasonCode,
              AiTextBlockCode.rereadField,
            );
            expect(
              _prepare(
                modelText: outgoing,
                field: forged,
                placeholders: table,
              ).blockedReasonCode,
              AiTextBlockCode.rereadField,
            );
          }
        }
      }
    });

    test(
      'description uses the numeric identity and current installation URL',
      () {
        final identity = _groupIdentity();
        final field = _groupField(identity);
        expect(field.resourceKey.canonical, identity.canonicalKey);
        expect(field.fieldName, AiWritableField.workItemDescription);
        expect(field.accountKey, identity.accountKey);
        expect(field.groupId, 7);
        expect(field.groupFullPath, 'team/sub');
        expect(field.projectId, isNull);
        expect(field.projectFullPath, isNull);
        expect(
          field.resourceWeb.toString(),
          'https://gitlab.example.com/gitlab/groups/team/sub/-/work_items/4',
        );
        final root = _groupIdentity(root: 'https://gitlab.example.com:8443');
        expect(
          _groupField(root).resourceWeb.toString(),
          'https://gitlab.example.com:8443/groups/team/sub/-/work_items/4',
        );
      },
    );

    test(
      'whole description and note bodies round trip; excerpts never mint',
      () {
        final identity = _groupIdentity();
        for (final note in <int?>[null, 12]) {
          final table = _groupTable(identity);
          final field = _groupField(identity, noteId: note);
          const original = '![a](/uploads/$_secret/a.png)';
          final outgoing = table.redactOutgoing(original, field: field);
          expect(outgoing, matches(r'^!\[a\]\(\[\[upload:u-[0-9]+\]\]\)$'));
          expect(outgoing, isNot(contains(_secret)));
          expect(
            _prepare(
              modelText: outgoing,
              field: field,
              placeholders: table,
            ).finalText,
            original,
          );

          final excerpt = _groupField(identity, noteId: note, complete: false);
          expect(
            table.redactOutgoing(original, field: excerpt),
            isNot(contains('[[upload:')),
          );
          expect(
            _prepare(
              modelText: outgoing,
              field: excerpt,
              placeholders: table,
            ).blockedReasonCode,
            AiTextBlockCode.fieldTooLong,
          );
        }
      },
    );

    test('cannot restore across group, IID, note or field', () {
      final identity = _groupIdentity();
      final table = _groupTable(identity);
      final source = _groupField(identity);
      final note = _groupField(identity, noteId: 12);
      const original = '![a](/uploads/$_secret/a.png)';
      final descriptionText = table.redactOutgoing(original, field: source);
      final noteText = table.redactOutgoing(original, field: note);
      expect(noteText, isNot(descriptionText));
      final otherField = AiFieldProvenance(
        resourceKey: source.resourceKey,
        fieldName: AiWritableField.workItemNote,
        completeValue: true,
        accountKey: identity.accountKey,
        groupId: identity.groupId,
        groupFullPath: identity.fullPath,
        resourceWeb: source.resourceWeb,
      );
      for (final target in <AiFieldProvenance>[
        _groupField(_groupIdentity(groupId: 8)),
        _groupField(_groupIdentity(iid: 5)),
        note,
        otherField,
        AiFieldProvenance(
          resourceKey: AiConflictKey(
            '(${identity.accountKey}, project:7, workItem, 4)',
          ),
          fieldName: source.fieldName,
          completeValue: true,
          projectId: 7,
          projectFullPath: 'team/sub',
        ),
      ]) {
        final result = _prepare(
          modelText: descriptionText,
          field: target,
          placeholders: table,
        );
        expect(
          result.policyBlocked,
          isTrue,
          reason: target.resourceKey.canonical,
        );
        expect(result.finalText, isNull);
        expect(result.blockedReasonCode, AiTextBlockCode.rereadField);
      }
      for (final target in <AiFieldProvenance>[
        _groupField(identity, noteId: 13),
        _groupField(_groupIdentity(iid: 5), noteId: 12),
        _groupField(_groupIdentity(groupId: 8), noteId: 12),
        source,
      ]) {
        expect(
          _prepare(
            modelText: noteText,
            field: target,
            placeholders: table,
          ).blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
      }
    });

    test('note numeric and GID aliases receive one number and source', () {
      final identity = _groupIdentity();
      final table = _groupTable(identity);
      final numeric = _groupField(identity, noteId: 12);
      const original = '![a](/uploads/$_secret/a.png)';
      final outgoing = table.redactOutgoing(original, field: numeric);
      for (final type in <String>['Note', 'DiscussionNote']) {
        final alias = AiFieldProvenance.groupWorkItem(
          identity: identity,
          completeValue: true,
          noteGid: 'gid://gitlab/$type/12',
        );
        expect(alias.sameField(numeric), isTrue);
        expect(alias.fieldName, AiWritableField.workItemNote);
        expect(table.redactOutgoing(original, field: alias), outgoing);
        expect(
          _prepare(
            modelText: outgoing,
            field: alias,
            placeholders: table,
          ).finalText,
          original,
        );
      }
      expect(table.length, 1);
      expect(
        () => AiFieldProvenance.groupWorkItem(
          identity: identity,
          completeValue: true,
          noteId: 12,
          noteGid: 'gid://gitlab/Note/13',
        ),
        throwsArgumentError,
      );
      for (final gid in <String>[
        '12',
        'gid://gitlab/WorkItem/12',
        'gid://gitlab/Note/012',
        'gid://gitlab/Note/9223372036854775808',
      ]) {
        expect(
          () => AiFieldProvenance.groupWorkItem(
            identity: identity,
            completeValue: true,
            noteGid: gid,
          ),
          throwsArgumentError,
        );
      }
    });

    test('rename preserves the key while resourceWeb uses the fresh path', () {
      final identity = _groupIdentity();
      final table = _groupTable(identity);
      final source = _groupField(identity);
      final renamed = _groupField(_groupIdentity(path: 'renamed/sub'));
      expect(renamed.sameField(source), isTrue);
      expect(
        renamed.resourceWeb.toString(),
        'https://gitlab.example.com/gitlab/groups/renamed/sub/-/work_items/4',
      );
      const original = '![a](/uploads/$_secret/a.png)';
      final outgoing = table.redactOutgoing(original, field: source);
      expect(table.redactOutgoing(original, field: renamed), outgoing);
      expect(table.length, 1);
      expect(
        _prepare(
          modelText: outgoing,
          field: renamed,
          placeholders: table,
        ).finalText,
        original,
      );
      const oldPath =
          '![a](https://gitlab.example.com/gitlab/groups/'
          'team/sub/-/uploads/$_secret/a.png)';
      final oldPathText = table.redactOutgoing(oldPath, field: source);
      expect(oldPathText, isNot(outgoing));
      expect(table.length, 2);
      expect(
        table.restoreIntoSameField(oldPathText, renamed).blockedReasonCode,
        AiTextBlockCode.rereadField,
      );
      const numericPath =
          '![a](https://gitlab.example.com/gitlab/'
          '-/group/7/uploads/$_secret/a.png)';
      final numericText = table.redactOutgoing(numericPath, field: source);
      expect(
        table.restoreIntoSameField(numericText, renamed).finalText,
        numericPath,
      );
    });

    test('group placeholders require the bound account and conversation', () {
      final identity = _groupIdentity();
      final source = _groupField(identity);
      final table = _groupTable(identity);
      const original = '![a](/uploads/$_secret/a.png)';
      final outgoing = table.redactOutgoing(original, field: source);
      for (final foreign in <VerifiedGroupWorkItemIdentity>[
        _groupIdentity(userId: 6),
        _groupIdentity(root: 'https://other.example.com/gitlab'),
        _groupIdentity(root: 'https://gitlab.example.com:8443/gitlab'),
        _groupIdentity(root: 'https://gitlab.example.com/other'),
      ]) {
        final target = _groupField(foreign);
        expect(target.resourceKey, isNot(source.resourceKey));
        expect(
          table.redactOutgoing(original, field: target),
          isNot(contains('[[upload:')),
        );
        expect(
          table.restoreIntoSameField(outgoing, target).blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
      }
      for (final emptyOrUnbound in <UploadPlaceholderTable>[
        UploadPlaceholderTable(instance: identity.instance),
        UploadPlaceholderTable(
          instance: identity.instance,
          accountKey: identity.accountKey,
        ),
        UploadPlaceholderTable(
          instance: identity.instance,
          accountKey: identity.accountKey,
          conversationId: '',
        ),
        UploadPlaceholderTable(
          instance: identity.instance,
          accountKey: '${identity.instance.key}#6',
          conversationId: 'chat',
        ),
        UploadPlaceholderTable(
          instance: GitLabInstance.parse('https://gitlab.example.com/other'),
          accountKey: identity.accountKey,
          conversationId: 'chat',
        ),
      ]) {
        expect(
          emptyOrUnbound.redactOutgoing(original, field: source),
          isNot(contains('[[upload:')),
        );
        expect(
          emptyOrUnbound.restoreIntoSameField(outgoing, source).policyBlocked,
          isTrue,
        );
        expect(emptyOrUnbound.length, 0);
      }
      final nextConversation = _groupTable(identity, conversation: 'next-chat');
      expect(
        nextConversation
            .restoreIntoSameField(outgoing, source)
            .blockedReasonCode,
        AiTextBlockCode.rereadField,
      );
      expect(nextConversation.length, 0);
    });

    test(
      'populated conversations and rebuilt tables reject each other tokens',
      () {
        final identity = _groupIdentity();
        final field = _groupField(identity);
        final first = _groupTable(identity);
        const original = '![a](/uploads/$_secret/a.png)';
        const other = '![a](/uploads/$_otherSecret/b.png)';
        final outgoing = first.redactOutgoing(original, field: field);
        for (final second in <UploadPlaceholderTable>[
          _groupTable(identity, conversation: 'next-chat'),
          _groupTable(identity),
        ]) {
          final secondOutgoing = second.redactOutgoing(other, field: field);
          expect(secondOutgoing, isNot(outgoing));
          expect(
            second.restoreIntoSameField(outgoing, field).blockedReasonCode,
            AiTextBlockCode.rereadField,
          );
          expect(
            first.restoreIntoSameField(secondOutgoing, field).blockedReasonCode,
            AiTextBlockCode.rereadField,
          );
          expect(
            second.restoreIntoSameField(secondOutgoing, field).finalText,
            other,
          );
        }
        expect(first.restoreIntoSameField(outgoing, field).finalText, original);
        expect(
          first
              .restoreIntoSameField('![a]([[upload:u-${'9' * 200}]])', field)
              .blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
      },
    );

    test('subpath group upload routes and relative links stay owner-bound', () {
      final identity = _groupIdentity();
      final field = _groupField(identity);
      for (final target in <String>[
        '/uploads/$_secret/a.png',
        '</uploads/$_secret/a.png>',
        '<../uploads/$_secret/a.png>',
        '<https://gitlab.example.com/gitlab/-/group/7/uploads/$_secret/a.png>',
        'https://gitlab.example.com/gitlab/-/group/7/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/groups/team/sub/-/uploads/$_secret/a.png',
        '../uploads/$_secret/a.png',
      ]) {
        final table = _groupTable(identity);
        final original = '![a]($target)';
        final outgoing = table.redactOutgoing(original, field: field);
        expect(outgoing, contains('[[upload:u-'), reason: target);
        expect(table.length, 1);
        expect(
          _prepare(
            modelText: outgoing,
            field: field,
            placeholders: table,
          ).finalText,
          original,
          reason: target,
        );
      }
      final table = _groupTable(identity);
      for (final target in <String>[
        './uploads/$_secret/a.png',
        'https://gitlab.example.com/-/group/7/uploads/$_secret/a.png',
        'https://gitlab.example.com/other/-/group/7/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/-/group/8/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/-/project/7/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/groups/other/-/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/team/sub/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/groups/team/sub/uploads/$_secret/a.png',
        'https://other.example.com/gitlab/-/group/7/uploads/$_secret/a.png',
        'https://gitlab.example.com:8443/gitlab/-/group/7/uploads/$_secret/a.png',
        '../../../../../../../-/group/7/uploads/$_secret/a.png',
      ]) {
        final outgoing = table.redactOutgoing('![a]($target)', field: field);
        expect(outgoing, isNot(contains('[[upload:')), reason: target);
        expect(outgoing, isNot(contains(_secret)), reason: target);
      }
      expect(table.length, 0);
    });

    test(
      'delivery cuts and project attachment refusal apply to group fields',
      () {
        final identity = _groupIdentity();
        final field = _groupField(identity);
        final table = _groupTable(identity);
        table.recordFieldDelivery(field, whole: false);
        expect(
          _prepare(
            modelText: 'replacement',
            field: field,
            placeholders: table,
          ).blockedReasonCode,
          AiTextBlockCode.fieldTooLong,
        );
        table.recordFieldDelivery(field, whole: true);
        expect(table.seenOnlyCut(field), isFalse);
        final attachment = _prepare(
          modelText: '[[attachment:att-1]]',
          field: field,
          placeholders: table,
          attachments: _attachments(),
        );
        expect(attachment.blockedReasonCode, AiTextBlockCode.attachmentScope);
        expect(attachment.finalText, isNull);
        for (final unbound in <UploadPlaceholderTable>[
          UploadPlaceholderTable(instance: identity.instance),
          UploadPlaceholderTable(
            instance: identity.instance,
            accountKey: '${identity.instance.key}#6',
            conversationId: 'foreign',
          ),
        ]) {
          unbound.recordFieldDelivery(field, whole: false);
          expect(
            _prepare(
              modelText: 'replacement',
              field: field,
              placeholders: unbound,
            ).blockedReasonCode,
            AiTextBlockCode.fieldTooLong,
          );
        }
      },
    );
  });

  group('§15 row 14 text safety', () {
    test('class A neutralizes column-zero quick actions', () {
      const samples = <String>['a\n/merge', 'a\r\n/approve', 'a\n\r/move x/y'];
      for (final sample in samples) {
        final prepared = _prepare(modelText: sample);
        expect(prepared.policyBlocked, isFalse, reason: sample);
        expect(prepared.finalText, isNotNull);
        expect(
          prepared.finalText!.split('\n').any((line) => line.startsWith('/')),
          isFalse,
          reason: sample,
        );
      }
    });

    test('class B keeps slashes and class A still neutralizes them', () {
      const sample = 'line\n/usr/bin/env\n@param int x\n@Override\n';
      final plain = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: sample,
        visibility: const AiVisibilityContext(targetProjectPath: 'group/proj'),
      );
      expect(plain.policyBlocked, isFalse);
      expect(plain.finalText, sample);
      expect(plain.confirmReasons, isEmpty);

      final comment = _prepare(modelText: sample);
      expect(comment.policyBlocked, isFalse);
      expect(
        comment.finalText!.split('\n').any((line) => line.startsWith('/')),
        isFalse,
      );
    });

    test('Java and Python mentions do not confirm; Markdown does', () {
      final java = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: '/** @param value */\n@Override\n@dataclass\n',
        visibility: const AiVisibilityContext(targetProjectPath: 'group/proj'),
      );
      expect(java.finalText, '/** @param value */\n@Override\n@dataclass\n');
      expect(
        java.confirmReasons,
        isNot(contains(AiFixedConfirmReason.massMention)),
      );

      final markdown = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: 'hi @a @b @c @d @e @f',
        visibility: const AiVisibilityContext(
          targetProjectPath: 'group/proj',
          renderedMarkdown: true,
        ),
      );
      expect(markdown.finalText, 'hi @a @b @c @d @e @f');
      expect(
        markdown.confirmReasons,
        contains(AiFixedConfirmReason.massMention),
      );
    });

    test('@all and a group mention require confirmation', () {
      final all = _prepare(modelText: 'ping @all');
      expect(all.confirmReasons, contains(AiFixedConfirmReason.massMention));
      final group = _prepare(modelText: 'ping @org/team');
      expect(group.confirmReasons, contains(AiFixedConfirmReason.massMention));
      final one = _prepare(modelText: 'ping @alice');
      expect(
        one.confirmReasons,
        isNot(contains(AiFixedConfirmReason.massMention)),
      );
    });

    test('class A blocks external images and class B markdown confirms', () {
      const image = '![x](https://evil.example/a.png)';
      final blocked = _prepare(modelText: image);
      expect(blocked.policyBlocked, isTrue);
      expect(blocked.finalText, isNull);
      expect(blocked.blockedReasonCode, AiTextBlockCode.externalMedia);

      final release = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: image,
        field: _field(AiWritableField.releaseDescription),
      );
      expect(release.policyBlocked, isFalse);
      expect(release.finalText, image);
      expect(
        release.confirmReasons,
        contains(AiFixedConfirmReason.externalMedia),
      );
      expect(release.externalDomains, contains('evil.example'));
    });

    test('out-of-scope closing patterns and cross-project refs confirm', () {
      final outside = _prepare(modelText: 'Closes other/proj#3');
      expect(
        outside.confirmReasons,
        contains(AiFixedConfirmReason.closingOrCrossProject),
      );
      final mr = _prepare(modelText: 'see other/proj!8');
      expect(
        mr.confirmReasons,
        contains(AiFixedConfirmReason.closingOrCrossProject),
      );
      final inside = _prepare(modelText: 'Closes #12');
      expect(
        inside.confirmReasons,
        isNot(contains(AiFixedConfirmReason.closingOrCrossProject)),
      );
      final same = _prepare(modelText: 'Closes group/proj#12');
      expect(
        same.confirmReasons,
        isNot(contains(AiFixedConfirmReason.closingOrCrossProject)),
      );
    });

    test('visibility pollution and unreadable visibility confirm', () {
      final polluted = _prepare(
        modelText: 'note',
        visibility: const AiVisibilityContext(
          targetProjectPath: 'group/proj',
          polluted: true,
        ),
      );
      expect(
        polluted.levelConfirmReasons,
        contains(AiLevelConfirmReason.visibilityPollution),
      );
      final unread = _prepare(
        modelText: 'note',
        visibility: const AiVisibilityContext(
          targetProjectPath: 'group/proj',
          visibilityUnreadable: true,
        ),
      );
      expect(
        unread.levelConfirmReasons,
        contains(AiLevelConfirmReason.visibilityPollution),
      );
      expect(polluted.policyBlocked, isFalse);
      expect(unread.finalText, 'note');
    });

    test('AI attribution is appended only for class A when enabled', () {
      final on = _prepare(modelText: 'hello', aiAttribution: true);
      expect(on.finalText, 'hello\n$aiAttributionLine');
      final off = _prepare(modelText: 'hello');
      expect(off.finalText, 'hello');
      expect(off.finalText, isNot(contains(aiAttributionLine)));
      final plain = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: 'hello',
        aiAttribution: true,
      );
      expect(plain.finalText, 'hello');
    });
  });

  group('§15 row 23 outgoing uploads and attachment text', () {
    test('provider text drops upload secrets in every listed shape', () {
      final redactor = Redactor(secrets: const _NoSecrets());
      final samples = <String>[
        '/uploads/$_secret/a.png',
        'https://gitlab.example.com/group/proj/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/-/project/7/uploads/$_secret/a.png',
        'https://gitlab.example.com/gitlab/-/group/3/uploads/$_secret/a.png',
        'https://other.example/uploads/$_secret/a.png',
        '```\nhttps://x.example/uploads/$_secret/a.png\n```',
        'job log uploads/$_secret/trace.txt done',
      ];
      for (final sample in samples) {
        final text = redactor.redactSource(sample).text;
        expect(text, isNot(contains(_secret)), reason: sample);
        expect(text.toLowerCase(), isNot(contains(_secret)));
      }
    });

    test('a cut through a secret or before the filename leaks nothing', () {
      final redactor = Redactor(secrets: const _NoSecrets());
      final mid = redactor.redactCutEnd(
        'log uploads/${_secret.substring(0, 10)}',
      );
      expect(mid.text, isNot(contains(_secret.substring(0, 10))));
      expect(mid.text.toLowerCase(), isNot(contains('uploads/')));

      final full = redactor.redactSource('log uploads/$_secret/a.png').text;
      expect(full, isNot(contains(_secret)));

      final beforeName = redactor.redactCutEnd('log uploads/$_secret/');
      expect(beforeName.text, isNot(contains(_secret)));
    });

    test('source-authored placeholders become ordinary markers', () {
      final outgoing = _table().redactOutgoing(
        'keep [[upload:u-1]] and [[attachment:att-1]]',
        field: _field(AiWritableField.issueDescription),
      );
      expect(outgoing, isNot(contains('[[upload:')));
      expect(outgoing, isNot(contains('[[attachment:')));
      expect(outgoing, contains('[REDACTED]'));
    });

    test('parseProjectUpload stays null for another project', () {
      final web = Uri.parse('https://gitlab.example.com/group/proj');
      expect(
        parseProjectUpload(
          Uri.parse('/-/project/99/uploads/$_secret/a.png'),
          projectId: 42,
          projectWeb: web,
        ),
        isNull,
      );
      expect(
        parseProjectUpload(
          Uri.parse('/uploads/$_secret/a.png'),
          projectId: 42,
          projectWeb: web,
        ),
        isNotNull,
      );
    });

    test('attachment placeholders expand only in same-project class A', () {
      final attachments = _attachments();
      final comment = _prepare(
        modelText: 'see [[attachment:att-1]]',
        attachments: attachments,
      );
      expect(comment.policyBlocked, isFalse, reason: comment.blockedReasonCode);
      expect(
        comment.finalText,
        'see ![$_noteName](/uploads/$_secret/shot.png)',
      );

      final otherProject = _prepare(
        modelText: 'see [[attachment:att-1]]',
        attachments: attachments,
        sameProjectClassA: false,
      );
      expect(otherProject.policyBlocked, isTrue);
      expect(otherProject.finalText, isNull);
      expect(otherProject.blockedReasonCode, AiTextBlockCode.attachmentScope);

      final file = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: 'see [[attachment:att-1]]',
        attachments: attachments,
        field: _field('fileContent'),
      );
      expect(file.blockedReasonCode, AiTextBlockCode.attachmentScope);
      expect(file.finalText, isNull);
    });

    test('unusable attachment markdown is not substituted', () {
      final broken = AttachmentSubstitution(<String, String?>{
        'att-1': '![shot](/uploads/$_secret/shot.png) tail',
        'att-2': '![bad](/uploads/$_secret/a.png)\r',
        'att-3': '![a[b]](/uploads/$_secret/a.png)',
        'att-4': null,
      });
      for (final id in <String>['att-1', 'att-2', 'att-3', 'att-4']) {
        final prepared = _prepare(
          modelText: '[[attachment:$id]]',
          attachments: broken,
        );
        expect(prepared.policyBlocked, isTrue, reason: id);
        expect(prepared.finalText, isNull);
        expect(prepared.blockedReasonCode, AiTextBlockCode.attachmentUnusable);
      }
    });

    test('a non-image server token is rebuilt as an image', () {
      final prepared = _prepare(
        modelText: '[[attachment:att-1]]',
        attachments: AttachmentSubstitution(<String, String?>{
          'att-1': '[shot](/uploads/$_secret/shot.png)',
        }),
      );
      expect(prepared.finalText, '![shot](/uploads/$_secret/shot.png)');
    });

    test('@all in a filename confirms and the preview is the final text', () {
      final prepared = _prepare(
        modelText: '[[attachment:att-1]]',
        attachments: AttachmentSubstitution(<String, String?>{
          'att-1': '![x](/uploads/$_secret/a@all.png)',
        }),
      );
      expect(prepared.policyBlocked, isFalse);
      expect(prepared.finalText, '![x](/uploads/$_secret/a@all.png)');
      expect(
        prepared.confirmReasons,
        contains(AiFixedConfirmReason.massMention),
      );
    });

    test('a cross-project filename reference confirms after substitution', () {
      final prepared = _prepare(
        modelText: '[[attachment:att-1]]',
        attachments: AttachmentSubstitution(<String, String?>{
          'att-1': '![other/proj#4](/uploads/$_secret/a.png)',
        }),
      );
      expect(prepared.finalText, '![other/proj#4](/uploads/$_secret/a.png)');
      expect(
        prepared.confirmReasons,
        contains(AiFixedConfirmReason.closingOrCrossProject),
      );
    });

    test('an attachment inside a link or URL is blocked', () {
      final prepared = _prepare(
        modelText: '![x]([[attachment:att-1]])',
        attachments: _attachments(),
      );
      expect(prepared.policyBlocked, isTrue);
      expect(prepared.finalText, isNull);
      expect(
        prepared.blockedReasonCode,
        AiTextBlockCode.badPlaceholderPosition,
      );
    });

    test('a restored upload that starts a line performs no mutation', () {
      final placeholders = _table();
      final field = _field(AiWritableField.issueDescription);
      placeholders.redactOutgoing(
        '![a](/uploads/$_secret/a.png)',
        field: field,
      );
      final prepared = _prepare(
        modelText: '[[upload:u-1]]',
        placeholders: placeholders,
        field: field,
      );
      expect(prepared.policyBlocked, isTrue);
      expect(prepared.finalText, isNull);
      expect(prepared.blockedReasonCode, AiTextBlockCode.quickAction);
    });
  });

  group('§15 row 32 upload restoration', () {
    test('issue, MR and note round trip without sending the secret', () {
      for (final name in <String>[
        AiWritableField.issueDescription,
        AiWritableField.mergeRequestDescription,
        AiWritableField.note,
        AiWritableField.discussion,
      ]) {
        final field = _field(name);
        final placeholders = _table();
        const original = 'before ![shot](/uploads/$_secret/a.png) after';
        final outgoing = placeholders.redactOutgoing(original, field: field);
        expect(outgoing, contains('[[upload:u-1]]'), reason: name);
        expect(outgoing, isNot(contains(_secret)), reason: name);
        expect(outgoing, isNot(contains('gitlab.example')), reason: name);
        final prepared = _prepare(
          modelText: outgoing,
          placeholders: placeholders,
          field: field,
        );
        expect(
          prepared.policyBlocked,
          isFalse,
          reason: prepared.blockedReasonCode,
        );
        expect(prepared.finalText, original, reason: name);
      }
    });

    test('absolute same-instance URLs round trip and hide the host', () {
      final field = _field(AiWritableField.issueDescription);
      final placeholders = _table();
      const original =
          '![shot](https://gitlab.example.com/group/proj/uploads/$_secret/a.png)';
      final outgoing = placeholders.redactOutgoing(original, field: field);
      expect(outgoing, isNot(contains('gitlab.example')));
      expect(outgoing, isNot(contains(_secret)));
      expect(outgoing, contains('[[upload:u-1]]'));
      expect(
        _prepare(
          modelText: outgoing,
          placeholders: placeholders,
          field: field,
        ).finalText,
        original,
      );
    });

    test('MR6b-2 release, milestone and snippet fields round trip here', () {
      for (final name in <String>[
        AiWritableField.releaseDescription,
        AiWritableField.milestoneDescription,
        AiWritableField.snippetDescription,
      ]) {
        final field = _field(name);
        final placeholders = _table();
        const original = 'note ![a](/uploads/$_secret/a.png)';
        final outgoing = placeholders.redactOutgoing(original, field: field);
        expect(outgoing, contains('[[upload:u-1]]'), reason: name);
        expect(
          _prepare(
            textClass: AiTextClass.plainContent,
            modelText: outgoing,
            placeholders: placeholders,
            field: field,
          ).finalText,
          original,
          reason: name,
        );
      }
    });

    test(
      'MR6b-3 work item description and note are accepted at this layer',
      () {
        for (final name in <String>[
          AiWritableField.workItemDescription,
          AiWritableField.workItemNote,
        ]) {
          final field = _field(name);
          final placeholders = _table();
          const original = '![a](/uploads/$_secret/a.png)';
          final outgoing = placeholders.redactOutgoing(original, field: field);
          expect(
            _prepare(
              modelText: outgoing,
              placeholders: placeholders,
              field: field,
            ).finalText,
            original,
            reason: name,
          );
        }
      },
    );

    test('the same id is refused in another field or a forged id', () {
      final placeholders = _table();
      final issue = _field(AiWritableField.issueDescription, key: 'issue:1');
      final other = _field(AiWritableField.issueDescription, key: 'issue:2');
      final note = _field(AiWritableField.note, key: 'note:9');
      placeholders.redactOutgoing(
        '![a](/uploads/$_secret/a.png)',
        field: issue,
      );
      final crossIssue = _prepare(
        modelText: '[[upload:u-1]]',
        placeholders: placeholders,
        field: other,
      );
      expect(crossIssue.blockedReasonCode, AiTextBlockCode.rereadField);
      expect(crossIssue.finalText, isNull);
      final crossNote = _prepare(
        modelText: 'see [[upload:u-1]]',
        placeholders: placeholders,
        field: note,
      );
      expect(crossNote.blockedReasonCode, AiTextBlockCode.rereadField);
      final file = _prepare(
        textClass: AiTextClass.plainContent,
        modelText: '[[upload:u-1]]',
        placeholders: placeholders,
        field: _field('fileContent', key: 'file'),
      );
      expect(file.blockedReasonCode, AiTextBlockCode.rereadField);

      final forged = _prepare(
        modelText: '[[upload:u-99]]',
        placeholders: placeholders,
        field: issue,
      );
      expect(forged.blockedReasonCode, AiTextBlockCode.rereadField);
      expect(forged.finalText, isNull);

      final restarted = _prepare(
        modelText: '[[upload:u-1]]',
        placeholders: _table(),
        field: issue,
      );
      expect(restarted.blockedReasonCode, AiTextBlockCode.rereadField);
    });

    test('illegal placeholder positions block even if the id exists', () {
      final placeholders = _table();
      final field = _field(AiWritableField.issueDescription);
      placeholders.redactOutgoing(
        '![a](/uploads/$_secret/a.png)',
        field: field,
      );
      for (final sample in <String>[
        'https://x.example/[[upload:u-1]]',
        '?d=[[upload:u-1]]',
        'x[[upload:u-1]]',
        '[[upload:u-1]]y',
      ]) {
        final prepared = _prepare(
          modelText: sample,
          placeholders: placeholders,
          field: field,
        );
        expect(prepared.policyBlocked, isTrue, reason: sample);
        expect(prepared.finalText, isNull, reason: sample);
        expect(
          prepared.blockedReasonCode,
          AiTextBlockCode.badPlaceholderPosition,
          reason: sample,
        );
      }
    });

    test('other-host uploads are ordinary markers, including inside code', () {
      final field = _field(AiWritableField.issueDescription);
      final placeholders = _table();
      const linked = '![s](https://x.example/uploads/$_secret/a.png)';
      final outgoing = placeholders.redactOutgoing(linked, field: field);
      expect(outgoing, contains('[REDACTED]'));
      expect(outgoing, isNot(contains('[[upload:')));
      expect(outgoing, isNot(contains(_secret)));
      expect(outgoing, isNot(contains('x.example')));

      const fenced = '```\nhttps://x.example/uploads/$_secret/a.png\n```';
      final code = placeholders.redactOutgoing(fenced, field: field);
      expect(code, isNot(contains(_secret)));
      expect(code, isNot(contains('[[upload:')));
      expect(code, contains('[REDACTED]'));
    });

    test('job logs and source are not restorable; user text asks to paste', () {
      final field = _field(AiWritableField.issueDescription);
      final logs = _table();
      final logText = logs.redactOutgoing(
        'log https://gitlab.example.com/group/proj/uploads/$_secret/a.png',
      );
      expect(logText, isNot(contains(_secret)));
      expect(logText, isNot(contains('[[upload:')));
      final source = _table().redactOutgoing(
        'const p = "/uploads/$_secret/a.png";',
      );
      expect(source, isNot(contains(_secret)));
      expect(source, isNot(contains('[[upload:')));

      final user = _table();
      const pasted = 'https://gitlab.example.com/uploads/$_secret/a.png';
      user.redactOutgoing(pasted, userMessage: true);
      final prepared = _prepare(
        modelText: pasted,
        placeholders: user,
        field: field,
      );
      expect(prepared.policyBlocked, isTrue);
      expect(prepared.finalText, isNull);
      expect(prepared.blockedReasonCode, AiTextBlockCode.pasteOnScreen);
    });

    test('two resources get different ids and keep them in either order', () {
      void check(bool issueFirst) {
        final placeholders = _table();
        final issue = _field(AiWritableField.issueDescription, key: 'issue:1');
        final mr = _field(AiWritableField.mergeRequestDescription, key: 'mr:2');
        const body = '![a](/uploads/$_secret/a.png)';
        final first = issueFirst ? issue : mr;
        final second = issueFirst ? mr : issue;
        final firstOut = placeholders.redactOutgoing(body, field: first);
        final secondOut = placeholders.redactOutgoing(body, field: second);
        expect(firstOut, contains('[[upload:u-1]]'));
        expect(secondOut, contains('[[upload:u-2]]'));
        expect(placeholders.length, 2);
        expect(
          _prepare(
            modelText: firstOut,
            placeholders: placeholders,
            field: first,
          ).finalText,
          body,
        );
        expect(
          _prepare(
            modelText: '[[upload:u-1]]',
            placeholders: placeholders,
            field: second,
          ).blockedReasonCode,
          AiTextBlockCode.rereadField,
        );
      }

      check(true);
      check(false);
    });

    test('the 1001st target is an ordinary marker', () {
      final placeholders = _table();
      final field = _field(AiWritableField.issueDescription);
      final body = StringBuffer();
      for (var i = 0; i < UploadPlaceholderTable.maxEntries; i++) {
        final secret = i.toRadixString(16).padLeft(32, '0');
        body.writeln('![n](/uploads/$secret/a.png)');
      }
      final outgoing = placeholders.redactOutgoing(
        body.toString(),
        field: field,
      );
      expect(placeholders.length, UploadPlaceholderTable.maxEntries);
      expect(outgoing, contains('[[upload:u-1000]]'));
      expect(placeholders.exceededEntryLimit, isFalse);

      final extra = placeholders.redactOutgoing(
        '![n](/uploads/${'f' * 32}/a.png)',
        field: field,
      );
      expect(placeholders.exceededEntryLimit, isTrue);
      expect(placeholders.length, UploadPlaceholderTable.maxEntries);
      expect(extra, contains('[REDACTED]'));
      expect(extra, isNot(contains('[[upload:')));
      expect(extra, isNot(contains('f' * 32)));
    });

    test('restore still judges secrets, mentions and cross-project refs', () {
      final placeholders = _table();
      final field = _field(AiWritableField.issueDescription);
      final outgoing = placeholders.redactOutgoing(
        '![a](/uploads/$_secret/a.png)',
        field: field,
      );
      final secret = _prepare(
        modelText: '$outgoing $_token',
        placeholders: placeholders,
        field: field,
        knownSecrets: const <String>{_token},
      );
      expect(secret.blockedReasonCode, AiTextBlockCode.secret);
      expect(secret.finalText, isNull);

      final exempt = _prepare(
        modelText: outgoing,
        placeholders: placeholders,
        field: field,
        knownSecrets: const <String>{_secret},
      );
      expect(exempt.policyBlocked, isFalse, reason: exempt.blockedReasonCode);
      expect(exempt.finalText, contains('/uploads/$_secret/a.png'));

      final mention = _prepare(
        modelText: '$outgoing @all',
        placeholders: placeholders,
        field: field,
      );
      expect(
        mention.confirmReasons,
        contains(AiFixedConfirmReason.massMention),
      );
      expect(mention.finalText, contains('/uploads/$_secret/a.png'));

      final cross = _prepare(
        modelText: '$outgoing other/proj#4',
        placeholders: placeholders,
        field: field,
      );
      expect(
        cross.confirmReasons,
        contains(AiFixedConfirmReason.closingOrCrossProject),
      );
    });

    test('the table string and provider text do not carry the secret', () {
      final placeholders = _table();
      final outgoing = placeholders.redactOutgoing(
        '![a](/uploads/$_secret/a.png)',
        field: _field(AiWritableField.issueDescription),
      );
      expect(placeholders.toString(), isNot(contains(_secret)));
      expect(outgoing, isNot(contains(_secret)));
      expect(outgoing, isNot(contains('/uploads/$_secret/')));
    });

    test('REST and GraphQL descriptions share one key and one number', () {
      final placeholders = _table();
      final rest = _field(AiWritableField.issueDescription, key: 'issue:7');
      final graph = _field(AiWritableField.issueDescription, key: 'issue:7');
      const original = '![a](/uploads/$_secret/a.png)';
      expect(
        placeholders.redactOutgoing(original, field: rest),
        placeholders.redactOutgoing(original, field: graph),
      );
      expect(placeholders.length, 1);
      expect(
        _prepare(
          modelText: '[[upload:u-1]]',
          placeholders: placeholders,
          field: graph,
        ).finalText,
        isNot(contains('[[upload:')),
      );
    });

    test('excerpt and truncated fields are not restorable', () {
      final field = _field(AiWritableField.issueDescription, complete: false);
      final outgoing = _table().redactOutgoing(
        '![a](/uploads/$_secret/a.png)',
        field: field,
      );
      expect(outgoing, isNot(contains('[[upload:')));
      expect(outgoing, isNot(contains(_secret)));
      final prepared = _prepare(modelText: 'rewrite', field: field);
      expect(prepared.blockedReasonCode, AiTextBlockCode.fieldTooLong);
      expect(prepared.finalText, isNull);
    });

    test('standard form works on an instance installed under a subpath', () {
      final placeholders = _table('https://gitlab.example.com/gitlab');
      final field = _field(
        AiWritableField.issueDescription,
        web: 'https://gitlab.example.com/gitlab/group/proj/-/issues/1',
      );
      const original = '![a](/uploads/$_secret/a.png)';
      final outgoing = placeholders.redactOutgoing(original, field: field);
      expect(outgoing, contains('[[upload:u-1]]'));
      expect(
        _prepare(
          modelText: outgoing,
          placeholders: placeholders,
          field: field,
        ).finalText,
        original,
      );
    });

    test('escaped, foreign and other-project uploads are not restorable', () {
      final placeholders = _table('https://gitlab.example.com/gitlab');
      final field = _field(
        AiWritableField.issueDescription,
        web: 'https://gitlab.example.com/gitlab/group/proj/-/issues/1',
      );
      final samples = <String>[
        '![a](../../../../../../uploads/$_secret/a.png)',
        '![a](//x.example/uploads/$_secret/a.png)',
        '![a](https://gitlab.example.com/other/group/proj/uploads/$_secret/a.png)',
        '![a](https://gitlab.example.com/gitlab/-/project/99/uploads/$_secret/a.png)',
        '![x](/uploads/$_secret/a.png](https://x.example/y.png))',
      ];
      for (final sample in samples) {
        final outgoing = placeholders.redactOutgoing(sample, field: field);
        expect(outgoing, isNot(contains('[[upload:')), reason: sample);
        expect(outgoing, isNot(contains(_secret)), reason: sample);
      }
    });

    test('img, titled image and autolink round trip in place', () {
      final cases = <String>[
        '<img src="/uploads/$_secret/a.png" width="300">',
        '![a](/uploads/$_secret/a.png "caption")',
        '<https://gitlab.example.com/group/proj/uploads/$_secret/a.png>',
      ];
      for (final original in cases) {
        final placeholders = _table();
        final field = _field(AiWritableField.issueDescription);
        final outgoing = placeholders.redactOutgoing(original, field: field);
        expect(outgoing, contains('[[upload:u-1]]'), reason: original);
        expect(outgoing, isNot(contains(_secret)), reason: original);
        expect(outgoing, isNot(contains('gitlab.example')), reason: original);
        expect(
          _prepare(
            modelText: outgoing,
            placeholders: placeholders,
            field: field,
          ).finalText,
          original,
          reason: original,
        );
      }
    });

    test(
      'removing an unseen other-host upload still requires confirmation',
      () {
        const current =
            'keep ![s](https://x.example/uploads/$_secret/a.png) tail';
        final prepared = _prepare(
          modelText: 'keep tail',
          currentFieldValue: current,
        );
        expect(prepared.policyBlocked, isFalse);
        expect(prepared.hiddenSpanCount, 1);
        expect(
          prepared.confirmReasons,
          contains(AiFixedConfirmReason.hiddenContentRemoved),
        );
        expect(prepared.finalText, 'keep tail');

        final unread = _prepare(
          modelText: 'replacement',
          placeholders: _table(),
          currentFieldValue: current,
        );
        expect(unread.hiddenSpanCount, 1);
        expect(
          unread.confirmReasons,
          contains(AiFixedConfirmReason.hiddenContentRemoved),
        );

        const two =
            '![a](https://x.example/uploads/$_secret/a.png)\n'
            '![b](https://y.example/uploads/$_otherSecret/b.png)';
        final both = _prepare(modelText: 'gone', currentFieldValue: two);
        expect(both.hiddenSpanCount, 2);
      },
    );

    test(
      'MR6b-2 fragment secret scan ignores text outside the new fragment',
      () {
        final clean = _prepare(
          textClass: AiTextClass.plainContent,
          modelText: 'old $_token stays',
          knownSecrets: const <String>{_token},
          secretFragments: const <String>['new line'],
        );
        expect(clean.policyBlocked, isFalse);
        expect(clean.finalText, 'old $_token stays');

        final hit = _prepare(
          textClass: AiTextClass.plainContent,
          modelText: 'old',
          knownSecrets: const <String>{_token},
          secretFragments: const <String>['new $_token'],
        );
        expect(hit.blockedReasonCode, AiTextBlockCode.secret);
        expect(hit.finalText, isNull);
      },
    );

    test('app placeholders survive a second redaction pass', () {
      final redactor = Redactor(secrets: const _NoSecrets());
      expect(redactor.redactSource('[[upload:u-4]]').text, '[REDACTED]');
      expect(
        redactor.redactSource('[[upload:u-4]]', keepAppPlaceholders: true).text,
        '[[upload:u-4]]',
      );
      expect(
        redactor
            .redactSource(
              '[[upload:u-4]] uploads/$_secret/a.png',
              keepAppPlaceholders: true,
            )
            .text,
        isNot(contains(_secret)),
      );
    });
  });
}

const _noteName = 'shot';

VerifiedGroupWorkItemIdentity _groupIdentity({
  String root = 'https://gitlab.example.com/gitlab',
  int userId = 5,
  int groupId = 7,
  int iid = 4,
  String path = 'team/sub',
}) => VerifiedGroupWorkItemIdentity.fromServerEvidence(
  instance: GitLabInstance.parse(root),
  expectedUserId: userId,
  actorUserId: userId,
  expectedGroupId: groupId,
  expectedFullPath: path,
  expectedIid: iid,
  apiOwner: Object(),
  generation: 1,
  readEpoch: 0,
  namespace: <String, Object?>{
    'id': 'gid://gitlab/Group/$groupId',
    'fullPath': path,
    'workItem': <String, Object?>{
      'id': 'gid://gitlab/WorkItem/91',
      'iid': '$iid',
      'project': null,
      'namespace': <String, Object?>{
        'id': 'gid://gitlab/Group/$groupId',
        'fullPath': path,
      },
    },
  },
)!;

AiFieldProvenance _groupField(
  VerifiedGroupWorkItemIdentity identity, {
  int? noteId,
  bool complete = true,
}) => AiFieldProvenance.groupWorkItem(
  identity: identity,
  completeValue: complete,
  noteId: noteId,
);

UploadPlaceholderTable _groupTable(
  VerifiedGroupWorkItemIdentity identity, {
  String conversation = 'group-chat',
}) => UploadPlaceholderTable(
  instance: identity.instance,
  accountKey: identity.accountKey,
  conversationId: conversation,
);

AiTextOutcome _prepare({
  AiTextClass textClass = AiTextClass.quickActionMarkdown,
  required String modelText,
  AiFieldProvenance? field,
  UploadPlaceholderTable? placeholders,
  Set<String> knownSecrets = const <String>{},
  bool aiAttribution = false,
  AiVisibilityContext visibility = _visibility,
  AttachmentSubstitution? attachments,
  bool sameProjectClassA = true,
  String? currentFieldValue,
  List<String>? secretFragments,
}) {
  return prepareWriteText(
    textClass: textClass,
    modelText: modelText,
    field: field ?? _field(AiWritableField.issueDescription),
    placeholders: placeholders ?? _table(),
    knownSecrets: knownSecrets,
    aiAttribution: aiAttribution,
    visibility: visibility,
    attachments: attachments,
    sameProjectClassA: sameProjectClassA,
    currentFieldValue: currentFieldValue,
    secretFragments: secretFragments,
  );
}

UploadPlaceholderTable _table([String root = 'https://gitlab.example.com']) =>
    UploadPlaceholderTable(instance: GitLabInstance.parse(root));

AiFieldProvenance _field(
  String fieldName, {
  String key = 'resource:1',
  bool complete = true,
  String? web,
}) => AiFieldProvenance(
  resourceKey: AiConflictKey(key),
  fieldName: fieldName,
  completeValue: complete,
  projectId: 42,
  projectFullPath: 'group/proj',
  resourceWeb: Uri.parse(
    web ?? 'https://gitlab.example.com/group/proj/-/issues/1',
  ),
);

AttachmentSubstitution _attachments() => AttachmentSubstitution(
  <String, String?>{'att-1': '![$_noteName](/uploads/$_secret/shot.png)'},
);

const _visibility = AiVisibilityContext(targetProjectPath: 'group/proj');

final class _NoSecrets implements KnownSecretsSource {
  const _NoSecrets();

  @override
  Iterable<String> get current => const <String>[];
}
