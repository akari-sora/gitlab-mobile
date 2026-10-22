import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import 'editor.dart';

/// The ordinary local comment draft, shared with the discussion tab. Opening
/// this editor never writes to GitLab; only the explicit Save action does.
Future<bool> openCommentEditor(
  BuildContext context, {
  required Account account,
  required GitLabApi api,
  required Project project,
  required String resource,
  required int iid,
  required bool Function() isCurrent,
  String? appendBody,
  ValueChanged<Route<dynamic>>? onRoute,
}) {
  if (!isCurrent()) return Future.value(false);
  final path = ['projects', '${project.id}', resource, '$iid'];
  return openEditor(
    context,
    account: account,
    api: api,
    projectId: project.id,
    projectPath: project.path,
    title: l10n.newComment,
    resource: '${path.join('/')}/root/new',
    subtitle: '${project.path} · ${resource == 'issues' ? '#' : '!'}$iid',
    fields: [
      EditField(
        'body',
        l10n.commentBody,
        required: true,
        lines: 9,
        markdown: true,
        quickActions: true,
        hint: l10n.markdownQuickActionsHint,
      ),
    ],
    appendValues: appendBody == null ? const {} : {'body': appendBody},
    isCurrent: () => isCurrent() && !api.isClosed,
    onRoute: onRoute,
    blockRetryOnWriteUncertain: true,
    save: (values) async {
      if (!isCurrent() || api.isClosed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      try {
        await api.writeRecord(
          'POST',
          [...path, 'notes'],
          {'body': values['body']},
        );
      } on ApiFailure catch (failure) {
        // A lost acknowledgement or server error cannot prove that GitLab
        // did not accept the comment. Preserve the local replay fence.
        if (failure.kind == FailureKind.cancelled ||
            failure.kind == FailureKind.server) {
          throw const ApiFailure(FailureKind.writeUncertain);
        }
        rethrow;
      }
    },
  );
}
