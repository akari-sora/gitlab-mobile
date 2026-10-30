import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

import '../../core/ai/ai_endpoint.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/ai_transport.dart';
import '../../core/ai/ai_wire_client.dart';
import '../../core/ai/wire/responses.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../ai/ai_chat_context.dart' show projectForAiChatOrigin;
import '../ai/ai_chat_controller.dart';
import '../ai/ai_chat_session.dart';
import '../ai/ai_history.dart';
import '../ai/ai_run_registry.dart';
import '../ai/ai_write_journal.dart';
import 'demo_data.dart';
import 'demo_scope.dart';

/// The demo's AI provider. It needs no key, and its host is on the reserved
/// `.invalid` domain; the transport never leaves the device anyway, because
/// [DemoAiAdapter] answers every request.
AiProviderConfig demoAiProvider() => AiProviderConfig(
  id: 'mergeline-demo',
  name: l10n.demoProviderName,
  presetId: 'custom',
  baseUrl: 'https://ai.$demoHost/v1',
  format: AiFormat.responses,
  model: 'sample-answers',
  authStyle: AiAuthStyle.bearer,
  caps: const AiCaps(
    tokenLimitField: AiTokenLimitField.maxOutputTokens,
    requiresKey: false,
    toolChoice: true,
  ),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

/// Builds the demo's conversations: the production chat controller with the
/// demo's journal and history, talking to [DemoAiAdapter].
AiChatSessionFactory demoAiSessionFactory({
  required AiWriteJournal journal,
  required AiHistoryCoordinator history,
}) =>
    ({
      required origin,
      required session,
      required settings,
      required runningCount,
      wireClientFactory,
    }) {
      final controller = AiChatController(
        origin: origin,
        session: session,
        settings: settings,
        runningCount: runningCount,
        wireClientFactory:
            ({required config, required apiKey, required conversationId}) =>
                AiWireClient(
                  transport: AiTransport(
                    endpoint: AiEndpoint.parse(
                      config.baseUrl,
                      allowLanCleartext: false,
                    ),
                    apiKey: apiKey ?? '',
                    authStyle: config.authStyle,
                    adapter: DemoAiAdapter(origin),
                  ),
                  wire: const ResponsesFormat(),
                  config: config,
                  conversationId: conversationId,
                  appVersion: 'demo',
                ),
        appInForeground: aiAppInForeground,
        clientMayStart: aiClientMayStart(session),
        writeJournal: journal,
        history: history,
      );
      return (
        session: controller,
        capacityChanged: controller.notifyCapacityChanged,
        dispose: controller.dispose,
      );
    };

/// A scripted model in the Responses format. The first answer describes the
/// page in a few sentences; a request for a comment, a new issue or closing
/// an issue becomes one tool call, which the app turns into its usual
/// confirmation card; after the tool result it says whether the change ran.
/// Every answer is marked as a sample. No AI provider receives anything.
final class DemoAiAdapter implements HttpClientAdapter {
  DemoAiAdapter(this.origin);

  final AiChatOrigin origin;

  /// Requests answered, for tests.
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (options.method != 'POST' ||
        options.uri.host != 'ai.$demoHost' ||
        options.uri.pathSegments.lastOrNull != 'responses') {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'not found', 'type': 'invalid_request_error'},
        }),
        404,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    final request = _decode(options.data);
    return ResponseBody.fromString(
      _reply(request),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  static Map<String, Object?> _decode(Object? data) {
    if (data is Map<String, Object?>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, Object?>) return decoded;
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }

  String _reply(Map<String, Object?> request) {
    final input = request['input'];
    final items = input is List<Object?> ? input : const <Object?>[];
    final last = items.lastOrNull;
    if (last is Map<String, Object?> &&
        last['type'] == 'function_call_output') {
      final output = '${last['output'] ?? ''}';
      final ran = RegExp(r':\s*(succeeded|noChange)\b').hasMatch(output);
      return _text(ran ? l10n.demoAiDone : l10n.demoAiNotDone);
    }
    final asked = _userText(items);
    final tools = <String>{
      for (final tool in request['tools'] as List<Object?>? ?? const [])
        if (tool is Map<String, Object?> && tool['name'] is String)
          tool['name']! as String,
    };
    return _toolCall(asked, tools) ?? _text(l10n.demoAiExplain(_subject));
  }

  /// The user's own words in the last message, after the page context.
  static String _userText(List<Object?> items) {
    for (final item in items.reversed) {
      if (item is! Map<String, Object?> || item['role'] != 'user') continue;
      final content = item['content'];
      final text = content is String
          ? content
          : [
              if (content is List<Object?>)
                for (final part in content)
                  if (part is Map<String, Object?> && part['text'] is String)
                    part['text']! as String,
            ].join('\n');
      final end = text.lastIndexOf('</gitlab_data>');
      return (end < 0 ? text : text.substring(end + '</gitlab_data>'.length))
          .trim();
    }
    return '';
  }

  String get _subject => switch (origin) {
    AiFileOrigin(:final path) => path,
    AiWorkItemOrigin(:final kind, :final iid, :final title) =>
      '${kind == AiWorkItemKind.issue ? '#' : '!'}$iid $title',
    AiJobOrigin(:final jobName) => jobName,
    AiGroupWorkItemOrigin(:final title) => title,
    AiProjectWorkItemFromGroupPageOrigin(:final title) => title,
    AiGeneralOrigin() => demoGroup['name'] as String,
  };

  String? _toolCall(String asked, Set<String> tools) {
    final text = asked.toLowerCase();
    final english = AppStrings(languageForTag('en')!);
    bool mentions(String Function(AppStrings) words) =>
        {...words(l10n).split(','), ...words(english).split(',')}
            .map((word) => word.trim().toLowerCase())
            .any((word) => word.isNotEmpty && _mentions(text, word));
    final project = projectForAiChatOrigin(origin);
    if (project == null) return null;
    final reason = asked.characters.take(200).toString();
    if (mentions((s) => s.demoKeywordsComment)) {
      final target = _commentTarget(project);
      if (target == null || !tools.contains('createNote')) return null;
      return _call('createNote', {
        'projectId': project.id,
        'resource': target.$1,
        'iid': target.$2,
        'body': l10n.demoAiNoteBody,
        'reason': reason,
      });
    }
    if (mentions((s) => s.demoKeywordsIssue)) {
      if (!tools.contains('createIssue')) return null;
      return _call('createIssue', {
        'projectId': project.id,
        'fields': {
          'title': l10n.demoAiIssueTitle,
          'description': l10n.demoAiNoteBody,
        },
        'reason': reason,
      });
    }
    if (mentions((s) => s.demoKeywordsClose)) {
      final target = _commentTarget(project);
      if (target == null ||
          target.$1 != 'issues' ||
          !tools.contains('updateIssue')) {
        return null;
      }
      return _call('updateIssue', {
        'projectId': project.id,
        'iid': target.$2,
        'fields': {'state_event': 'close'},
        'reason': reason,
      });
    }
    return null;
  }

  /// Scripts that separate words with spaces and inflect them (Latin,
  /// Cyrillic, Greek) match whole words, so "close" is not found in
  /// "closed"; the catalogs list the forms they need. Elsewhere (Chinese,
  /// Japanese, Korean particles, Thai, Arabic, Devanagari) a keyword is
  /// found anywhere in the text.
  static bool _mentions(String text, String word) {
    if (!_spacedScript.hasMatch(word)) return text.contains(word);
    return RegExp(
      '(?<![\\p{L}\\p{M}\\p{N}])${RegExp.escape(word)}(?![\\p{L}\\p{M}\\p{N}])',
      unicode: true,
    ).hasMatch(text);
  }

  static final _spacedScript = RegExp(
    r"^[\p{Script=Latin}\p{Script=Cyrillic}\p{Script=Greek}\p{M}\s'’-]+$",
    unicode: true,
  );

  /// The issue or merge request a comment goes to: the page's own, else the
  /// sample project's open bug.
  (String, int)? _commentTarget(Project project) => switch (origin) {
    AiWorkItemOrigin(:final kind, :final iid) => (
      kind == AiWorkItemKind.issue ? 'issues' : 'merge_requests',
      iid,
    ),
    _ when project.id == demoPlannerId => ('issues', demoDefaultIssue),
    _ => null,
  };

  static int _calls = 0;

  static String _call(String name, Map<String, Object?> arguments) => _event({
    'type': 'response.completed',
    'response': {
      'status': 'completed',
      'output': [
        {
          'type': 'function_call',
          'id': 'fc_demo_${++_calls}',
          'call_id': 'call_demo_$_calls',
          'name': name,
          'arguments': jsonEncode(arguments),
          'status': 'completed',
        },
      ],
    },
  });

  /// The answer streamed in short pieces, then the complete response.
  static String _text(String text) {
    final out = StringBuffer(_event({'type': 'response.created'}));
    for (var start = 0; start < text.length; start += 24) {
      out.write(
        _event({
          'type': 'response.output_text.delta',
          'output_index': 0,
          'delta': text.substring(start, (start + 24).clamp(0, text.length)),
        }),
      );
    }
    out.write(
      _event({
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {
                  'type': 'output_text',
                  'text': text,
                  'annotations': <Object?>[],
                },
              ],
            },
          ],
        },
      }),
    );
    return out.toString();
  }

  static String _event(Object value) => 'data: ${jsonEncode(value)}\n\n';
}
