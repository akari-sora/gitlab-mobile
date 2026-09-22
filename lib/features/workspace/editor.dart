import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';
import 'attachment_picker.dart';
import 'markdown_edit.dart';
import 'picker_sheet.dart';

const _draftStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  ),
);
String _draftPrefix(Account account) =>
    'draft.v2.${base64Url.encode(utf8.encode(account.key))}.';
Future<void> clearSecureDrafts(Account account) async {
  final entries = await _draftStorage.readAll();
  for (final key in entries.keys.where(
    (key) => key.startsWith(_draftPrefix(account)),
  )) {
    await _draftStorage.delete(key: key);
  }
}

class EditField {
  const EditField(
    this.key,
    this.label, {
    this.value = '',
    this.required = false,
    this.lines = 1,
    this.hint,
    this.markdown = false,
  }) : source = null,
       multi = false;
  const EditField.picker(
    this.key,
    this.label, {
    required this.source,
    this.multi = false,
    this.value = '',
    this.required = false,
    this.hint,
  }) : lines = 1,
       markdown = false;
  final String key, label, value;
  final bool required, multi, markdown;
  final int lines;
  final String? hint;
  final PickerSource? source;
}

Map<String, dynamic> editorSubmission(List<EditField> fields, Map<String, String> values) {
  final body = <String, dynamic>{};
  for (final field in fields) {
    final raw = values[field.key] ?? '';
    switch (field.source) {
      case null:
        body[field.key] = raw;
      case PickerSource.labels:
        body[field.key] = decodeChoices(raw, source: PickerSource.labels).map((choice) => choice.name).join(', ');
      case PickerSource.members:
        final ids = <int>[];
        for (final choice in decodeChoices(raw, source: PickerSource.members)) {
          final id = int.tryParse(choice.id);
          if (id != null) ids.add(id);
        }
        body[field.key] = ids;
      case PickerSource.branches:
        final choices = decodeChoices(raw, source: PickerSource.branches);
        body[field.key] = choices.isEmpty ? '' : choices.first.name;
    }
  }
  return body;
}

/// Reserved in persisted drafts. Edit field keys never start with `__`.
const _draftBaseKey = '__base';

typedef SaveEditor = Future<void> Function(Map<String, String> values);
Future<bool> openEditor(
  BuildContext context, {
  required Account account,
  required String title,
  required String resource,
  required List<EditField> fields,
  required SaveEditor save,
  String? subtitle,
  String? baseRevision,
  bool persistent = true,
  GitLabApi? api,
  int? projectId,
  String? projectPath,
  AttachmentPicker? attachments,
}) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ResourceEditor(
          account: account,
          title: title,
          resource: resource,
          fields: fields,
          save: save,
          subtitle: subtitle,
          baseRevision: baseRevision,
          persistent: persistent,
          api: api,
          projectId: projectId,
          projectPath: projectPath,
          attachments: attachments,
        ),
      ),
    ) ??
    false;

class ResourceEditor extends StatefulWidget {
  const ResourceEditor({
    super.key,
    required this.account,
    required this.title,
    required this.resource,
    required this.fields,
    required this.save,
    this.subtitle,
    this.baseRevision,
    this.persistent = true,
    this.api,
    this.projectId,
    this.projectPath,
    this.attachments,
  });
  final Account account;
  final String title, resource;
  final List<EditField> fields;
  final SaveEditor save;
  final String? subtitle;
  /// `updated_at` the fields were built from. Absent for creation editors.
  final String? baseRevision;
  final bool persistent;
  final GitLabApi? api;
  final int? projectId;
  final String? projectPath;
  final AttachmentPicker? attachments;
  @override
  State<ResourceEditor> createState() => _ResourceEditorState();
}

class _ResourceEditorState extends State<ResourceEditor> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  final _picked = <String, List<PickerChoice>>{};
  late final String _key;
  Timer? _timer;
  Future<void> _writes = Future<void>.value();
  bool _loading = true, _saving = false, _done = false, _dirty = false, _draftUnavailable = false, _preview = false, _guarding = false;
  int _operation = 0, _pickerEpoch = 0;
  Map<String, dynamic>? _staleDraft;
  bool _staleDraftUnknown = false;
  String? _uploadingName;
  TextSelection? _markdownSelection;
  ApiFailure? _error;
  bool get _locked => _saving || _guarding;

  @override
  void initState() {
    super.initState();
    _key = '${_draftPrefix(widget.account)}${base64Url.encode(utf8.encode(widget.resource))}';
    for (final field in widget.fields) {
      if (field.source == null) {
        final controller = TextEditingController(text: field.value);
        _controllers[field.key] = controller;
        if (field.markdown) {
          final node = FocusNode();
          _focus[field.key] = node;
          controller.addListener(() {
            if (node.hasFocus && controller.selection.isValid) _markdownSelection = controller.selection;
          });
        }
      } else {
        _picked[field.key] = decodeChoices(field.value, source: field.source);
      }
    }
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final raw = widget.persistent ? await _draftStorage.read(key: _key) : null;
      if (raw != null && mounted) {
        final value = jsonDecode(raw);
        if (value is Map<String, dynamic>) {
          final storedBase = value[_draftBaseKey];
          final current = widget.baseRevision;
          // Editing an existing resource: a draft is applied only when it was
          // written against the revision on screen. A draft from an older
          // app build carries no revision at all; that is "unknown", not
          // "current", so it is held back the same way.
          if (current != null && (storedBase is! String || storedBase != current)) {
            _staleDraft = value;
            _staleDraftUnknown = storedBase is! String;
          } else {
            _applyFieldMap(value);
            _dirty = true;
          }
        }
      }
    } catch (_) {
      _draftUnavailable = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _applyFieldMap(Map<String, dynamic> value) {
    for (final field in widget.fields) {
      final stored = value[field.key];
      if (stored is! String) continue;
      if (field.source == null) {
        _controllers[field.key]?.text = stored;
      } else {
        _picked[field.key] = decodeChoices(stored, source: field.source);
      }
    }
  }

  void _applyStaleDraft() {
    final draft = _staleDraft;
    if (draft == null || _locked) return;
    _timer?.cancel();
    _dirty = false;
    _staleDraft = null;
    _applyFieldMap(draft);
    _dirty = true;
    _pickerEpoch++;
    _persist();
    if (mounted) setState(() {});
  }

  Future<void> _discardStaleDraft() async {
    if (_locked || _staleDraft == null) return;
    _timer?.cancel();
    _dirty = false;
    try {
      await _draftStorage.delete(key: _key);
    } catch (_) {
      _draftUnavailable = true;
      if (mounted) setState(() {});
      return;
    }
    if (!mounted) return;
    setState(() => _staleDraft = null);
  }

  Map<String, String> _draftValues() {
    final map = <String, String>{};
    for (final field in widget.fields) {
      if (field.source == null) {
        map[field.key] = _controllers[field.key]?.text ?? '';
      } else {
        map[field.key] = encodeChoices(_picked[field.key] ?? const []);
      }
    }
    return map;
  }

  Map<String, String> _storedDraft() {
    final map = _draftValues();
    final base = widget.baseRevision;
    if (base != null) map[_draftBaseKey] = base;
    return map;
  }

  void _persist() {
    // While a stale draft is held, keystrokes, leave, and dispose must not
    // replace the stored copy. Apply persists only after the hold is cleared.
    if (_done || !widget.persistent || !_dirty || _staleDraft != null) return;
    final data = jsonEncode(_storedDraft());
    _writes = _writes.then((_) => _draftStorage.write(key: _key, value: data)).catchError((Object _) {
      _draftUnavailable = true;
      if (mounted) setState(() {});
    });
  }

  void _changed(String _) {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), _persist);
  }

  void _apply(String key, MarkupEdit edit) {
    final controller = _controllers[key];
    if (controller == null) return;
    controller.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection(baseOffset: edit.base, extentOffset: edit.extent),
    );
    _changed('');
    _focus[key]?.requestFocus();
  }

  void _markup(String key, MarkupEdit Function(String text, int start, int end) build) {
    final controller = _controllers[key];
    if (controller == null || _locked) return;
    final selection = controller.selection;
    _apply(key, build(
      controller.text,
      selection.isValid ? selection.start : -1,
      selection.isValid ? selection.end : -1,
    ));
  }

  Future<void> _mention(String key) async {
    final api = widget.api;
    final projectId = widget.projectId;
    final controller = _controllers[key];
    if (api == null || projectId == null || controller == null) {
      showFailure(context, const ApiFailure(FailureKind.unsupported));
      return;
    }
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : -1;
    final end = selection.isValid ? selection.end : -1;
    final picked = await showChoicePicker(
      context,
      api: api,
      account: widget.account,
      projectId: projectId,
      source: PickerSource.members,
      multi: false,
      title: '提及',
      initial: const [],
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final username = picked.first.username;
    if (username == null || username.isEmpty) return;
    _apply(key, insertMention(controller.text, start, end, username));
  }

  Future<void> _attach(String key, {required bool image}) async {
    final api = widget.api;
    final projectId = widget.projectId;
    final controller = _controllers[key];
    if (api == null || projectId == null || controller == null) {
      showFailure(context, const ApiFailure(FailureKind.unsupported));
      return;
    }
    if (_locked) return;
    final operation = ++_operation;
    final selection = controller.selection;
    final start = selection.isValid ? selection.start : -1;
    final end = selection.isValid ? selection.end : -1;
    setState(() => _guarding = true);
    final picker = widget.attachments ?? const PluginAttachmentPicker();
    try {
      final picked = image ? await picker.pickImage() : await picker.pickFile();
      if (!mounted || operation != _operation) return;
      if (picked == null) return;
      setState(() => _uploadingName = picked.filename);
      final result = await api.uploadProjectFile(
        projectId,
        filename: picked.filename,
        bytes: picked.bytes,
        contentType: picked.contentType,
      );
      if (!mounted || operation != _operation) return;
      final markdown = result['markdown'];
      if (markdown is! String || markdown.isEmpty) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      _apply(key, insertText(controller.text, start, end, markdown, breakBefore: true));
    } catch (error) {
      if (mounted && operation == _operation) showFailure(context, error);
    } finally {
      if (operation == _operation) {
        _guarding = false;
        _uploadingName = null;
        if (mounted) setState(() {});
      }
    }
  }

  void _setPreview(bool preview) {
    final field = _markdownField();
    final controller = field == null ? null : _controllers[field.key];
    if (preview && field != null && controller != null && _focus[field.key]?.hasFocus == true && controller.selection.isValid) {
      _markdownSelection = controller.selection;
    }
    setState(() => _preview = preview);
    final saved = _markdownSelection;
    if (preview || controller == null || saved == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (saved.start <= controller.text.length && saved.end <= controller.text.length) {
        controller.selection = saved;
      }
    });
  }

  EditField? _markdownField() {
    for (final field in widget.fields) {
      if (field.markdown) return field;
    }
    return null;
  }

  Future<void> _save() async {
    if (_locked || _loading || _staleDraft != null || _form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    _timer?.cancel();
    _persist();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(_draftValues());
      _done = true;
      await _writes;
      if (widget.persistent) {
        try {
          await _draftStorage.delete(key: _key);
        } catch (_) {
          /* Do not resend a successful remote write. */
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = safeFailure(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _leave() async {
    if (_locked) return;
    _timer?.cancel();
    _persist();
    await _writes;
    if (!mounted) return;
    if (_dirty && _draftUnavailable &&
        !await confirmAction(context, '離開編輯器？', '安全儲存不可用，這份草稿可能無法在重新開啟後恢復。')) {
      return;
    }
    if (mounted) Navigator.pop(context, false);
  }

  @override
  void dispose() {
    _operation++;
    _timer?.cancel();
    _persist();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      final route = ModalRoute.of(context);
      final leaving = _leave();
      if (route == null) {
        unawaited(leaving);
        return;
      }
      RouteExit.track(route, leaving);
    },
    child: Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        leading: IconButton(
          tooltip: '保留草稿並返回',
          icon: const Icon(Icons.close),
          onPressed: _locked ? null : _leave,
        ),
        title: Text(widget.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const Key('editorSave'),
              onPressed: _locked || _loading || _staleDraft != null ? null : _save,
              child: Text(_saving ? '送出中…' : '儲存'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const ListSkeleton()
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_staleDraft != null) _staleDraftNotice(),
                    Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            widget.subtitle ?? '@${widget.account.user.username} · ${widget.account.instance.base.host}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (_draftUnavailable)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('安全草稿儲存不可用。送出失敗時內容仍會保留在此畫面。'),
                            ),
                          if (_error != null)
                            FailureNotice(
                              _error!,
                              account: widget.account,
                              resourceLabel: widget.resource,
                              onSwitchAccount: endSessionFrom(context),
                            ),
                          for (final field in widget.fields)
                            Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: field.markdown
                                  ? _markdownBlock(field)
                                  : field.source == null
                                  ? _textField(field)
                                  : _pickerField(field),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );

  Widget _staleDraftNotice() => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_staleDraftUnknown
            ? '草稿沒有版本資訊（來自舊版 App），無法確認是否比伺服器內容新。'
            : '草稿來自較舊的版本，伺服器內容已在之後變更。'),
        const SizedBox(height: 4),
        Wrap(spacing: 8, children: [
          TextButton(onPressed: _locked ? null : _applyStaleDraft, child: const Text('套用草稿')),
          TextButton(
            onPressed: _locked ? null : () => unawaited(_discardStaleDraft()),
            child: const Text('捨棄草稿'),
          ),
        ]),
      ],
    ),
  );

  Widget _textField(EditField field) => TextFormField(
    key: ValueKey('editor-${field.key}'),
    controller: _controllers[field.key],
    focusNode: _focus[field.key],
    enabled: !_locked,
    minLines: field.lines,
    maxLines: field.lines == 1 ? 1 : null,
    keyboardType: field.lines > 1 ? TextInputType.multiline : TextInputType.text,
    textCapitalization: TextCapitalization.none,
    scrollPadding: EdgeInsets.fromLTRB(20, 20, 20, field.markdown ? 80 : 20),
    onChanged: _changed,
    decoration: InputDecoration(labelText: field.label, helperText: field.hint),
    validator: (value) => field.required && (value == null || value.trim().isEmpty) ? '此欄位必填' : null,
  );

  Widget _markdownBlock(EditField field) {
    final path = widget.projectPath;
    final web = path == null ? null : widget.account.instance.projectWeb(path);
    return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(minimumSize: const Size(48, 48)),
          segments: const [
            ButtonSegment(value: false, label: Text('編輯'), tooltip: '編輯'),
            ButtonSegment(value: true, label: Text('預覽'), tooltip: '預覽'),
          ],
          selected: {_preview},
          onSelectionChanged: _locked ? null : (selected) => _setPreview(selected.first),
        ),
      ),
      const SizedBox(height: 8),
      if (_preview)
        InputDecorator(
          decoration: InputDecoration(labelText: field.label, helperText: field.hint),
          child: MarkdownView(_controllers[field.key]?.text ?? '',
            base: web, api: widget.api, projectId: widget.projectId, projectWeb: web),
        ),
      Visibility(
        visible: !_preview,
        maintainState: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _textField(field),
            const SizedBox(height: 4),
            _toolbar(field.key),
            if (_uploadingName != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('上傳中 ${_uploadingName!}…')),
                ]),
              ),
          ],
        ),
      ),
    ],
    );
  }

  Widget _toolbar(String key) {
    final tools = <(String, IconData, MarkupEdit Function(String, int, int))>[
      ('粗體', Icons.format_bold, (text, start, end) => wrapSelection(text, start, end, '**', '**')),
      ('斜體', Icons.format_italic, (text, start, end) => wrapSelection(text, start, end, '*', '*')),
      ('行內程式碼', Icons.code, (text, start, end) => wrapSelection(text, start, end, '`', '`')),
      ('程式碼區塊', Icons.data_object, insertCodeBlock),
      ('連結', Icons.link, insertLink),
      ('項目符號清單', Icons.format_list_bulleted, (text, start, end) => prefixLines(text, start, end, '- ')),
      ('編號清單', Icons.format_list_numbered, (text, start, end) => prefixLines(text, start, end, '1. ')),
      ('待辦項目', Icons.checklist, (text, start, end) => prefixLines(text, start, end, '- [ ] ')),
      ('引用', Icons.format_quote, (text, start, end) => prefixLines(text, start, end, '> ')),
      ('標題', Icons.title, (text, start, end) => prefixLines(text, start, end, '## ')),
    ];
    return TextFieldTapRegion(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final tool in tools)
            IconButton(
              tooltip: tool.$1,
              onPressed: _locked ? null : () => _markup(key, tool.$3),
              icon: Icon(tool.$2),
            ),
          IconButton(
            tooltip: '提及',
            onPressed: _locked ? null : () { unawaited(_mention(key)); },
            icon: const Icon(Icons.alternate_email),
          ),
          IconButton(
            tooltip: '附加圖片',
            onPressed: _locked ? null : () { unawaited(_attach(key, image: true)); },
            icon: const Icon(Icons.image_outlined),
          ),
          IconButton(
            tooltip: '附加檔案',
            onPressed: _locked ? null : () { unawaited(_attach(key, image: false)); },
            icon: const Icon(Icons.attach_file),
          ),
        ]),
      ),
    );
  }

  Widget _pickerField(EditField field) {
    final source = field.source;
    if (source == null) return const SizedBox.shrink();
    return FormField<List<PickerChoice>>(
      key: ValueKey('picked-${field.key}-$_pickerEpoch'),
      initialValue: List<PickerChoice>.of(_picked[field.key] ?? const []),
      validator: (value) => field.required && (value == null || value.isEmpty) ? '此欄位必填' : null,
      builder: (state) {
        final selected = state.value ?? const <PickerChoice>[];
        return InkWell(
          key: ValueKey('editor-${field.key}'),
          onTap: _locked ? null : () async {
            final api = widget.api;
            final projectId = widget.projectId;
            if (api == null || projectId == null) {
              showFailure(context, const ApiFailure(FailureKind.unsupported));
              return;
            }
            final next = await showChoicePicker(
              context,
              api: api,
              account: widget.account,
              projectId: projectId,
              source: source,
              multi: field.multi,
              title: field.label,
              initial: selected,
            );
            if (next == null || !mounted) return;
            final choices = List<PickerChoice>.of(next);
            state.didChange(choices);
            setState(() => _picked[field.key] = choices);
            _changed('');
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: field.label,
              helperText: field.hint,
              errorText: state.errorText,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Align(
                alignment: Alignment.centerLeft,
                child: selected.isEmpty
                    ? Text('尚未選擇', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
                    : Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final choice in selected)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: PickerChoiceLabel(choice, source, compact: true),
                            ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
