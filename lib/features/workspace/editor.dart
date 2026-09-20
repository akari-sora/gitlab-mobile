import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/failure.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';

const _draftStorage = FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device));
String _draftPrefix(Account account) => 'draft.v2.${base64Url.encode(utf8.encode(account.key))}.';
Future<void> clearSecureDrafts(Account account) async {
  final entries = await _draftStorage.readAll();
  for (final key in entries.keys.where((key) => key.startsWith(_draftPrefix(account)))) {
    await _draftStorage.delete(key: key);
  }
}
class EditField {
  const EditField(this.key, this.label, {this.value = '', this.required = false, this.lines = 1, this.hint});
  final String key, label, value;
  final bool required;
  final int lines;
  final String? hint;
}
typedef SaveEditor = Future<void> Function(Map<String, String> values);
Future<bool> openEditor(BuildContext context, {required Account account, required String title,
    required String resource, required List<EditField> fields, required SaveEditor save,
    String? subtitle, bool persistent = true}) async =>
  await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ResourceEditor(
    account: account, title: title, resource: resource, fields: fields,
    save: save, subtitle: subtitle, persistent: persistent))) ?? false;

class ResourceEditor extends StatefulWidget {
  const ResourceEditor({super.key, required this.account, required this.title, required this.resource,
    required this.fields, required this.save, this.subtitle, this.persistent = true});
  final Account account;
  final String title, resource;
  final List<EditField> fields;
  final SaveEditor save;
  final String? subtitle;
  final bool persistent;
  @override
  State<ResourceEditor> createState() => _ResourceEditorState();
}
class _ResourceEditorState extends State<ResourceEditor> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  late final String _key;
  Timer? _timer;
  Future<void> _writes = Future<void>.value();
  bool _loading = true, _saving = false, _done = false, _dirty = false, _draftUnavailable = false;
  ApiFailure? _error;
  @override
  void initState() {
    super.initState();
    _key = '${_draftPrefix(widget.account)}${base64Url.encode(utf8.encode(widget.resource))}';
    for (final field in widget.fields) { _controllers[field.key] = TextEditingController(text: field.value); }
    unawaited(_restore());
  }
  Future<void> _restore() async {
    try {
      final raw = widget.persistent ? await _draftStorage.read(key: _key) : null;
      if (raw != null && mounted) {
        final value = jsonDecode(raw);
        if (value is Map<String, dynamic>) {
          for (final entry in _controllers.entries) {
            if (value[entry.key] is String) { entry.value.text = value[entry.key] as String; }
          }
          _dirty = true;
        }
      }
    } catch (_) { _draftUnavailable = true; }
    if (mounted) { setState(() => _loading = false); }
  }
  Map<String, String> _values() => _controllers.map((key, value) => MapEntry(key, value.text));
  void _persist() {
    if (_done || !widget.persistent || !_dirty) { return; }
    final data = jsonEncode(_values());
    _writes = _writes.then((_) => _draftStorage.write(key: _key, value: data)).catchError((Object _) {
      _draftUnavailable = true;
      if (mounted) { setState(() {}); }
    });
  }
  void _changed(String _) {
    _dirty = true; _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 350), _persist);
  }
  Future<void> _save() async {
    if (_saving || _loading || _form.currentState?.validate() != true) { return; }
    FocusScope.of(context).unfocus(); _timer?.cancel(); _persist();
    setState(() { _saving = true; _error = null; });
    try {
      await widget.save(_values());
      _done = true;
      await _writes;
      if (widget.persistent) {
        try { await _draftStorage.delete(key: _key); } catch (_) { /* Do not resend a successful remote write. */ }
      }
      if (mounted) { Navigator.pop(context, true); }
    } catch (e) { if (mounted) { setState(() => _error = safeFailure(e)); } }
    finally { if (mounted) { setState(() => _saving = false); } }
  }
  Future<void> _leave() async {
    if (_saving) { return; }
    _timer?.cancel(); _persist(); await _writes;
    if (!mounted) { return; }
    if (_dirty && _draftUnavailable &&
        !await confirmAction(context, '離開編輯器？', '安全儲存不可用，這份草稿可能無法在重新開啟後恢復。')) {
      return;
    }
    if (mounted) { Navigator.pop(context, false); }
  }
  @override
  void dispose() {
    _timer?.cancel(); _persist();
    for (final controller in _controllers.values) { controller.dispose(); }
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => PopScope(canPop: false,
    onPopInvokedWithResult: (didPop, _) { if (!didPop) { unawaited(_leave()); } },
    child: Scaffold(appBar: AppBar(leading: IconButton(tooltip: '保留草稿並返回', icon: const Icon(Icons.close),
      onPressed: _saving ? null : _leave), title: Text(widget.title), actions: [
        Padding(padding: const EdgeInsets.only(right: 12), child: FilledButton(key: const Key('editorSave'),
          onPressed: _saving || _loading ? null : _save, child: Text(_saving ? '送出中…' : '儲存'))),
      ]), body: SafeArea(child: _loading ? const ListSkeleton() : SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), child: Form(key: _form, child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.subtitle ?? '@${widget.account.user.username} · ${widget.account.instance.base.host}',
              style: Theme.of(context).textTheme.bodySmall),
            if (_draftUnavailable) const Padding(padding: EdgeInsets.only(top: 12),
              child: Text('安全草稿儲存不可用。送出失敗時內容仍會保留在此畫面。')),
            if (_error != null) FailureNotice(_error!),
            for (final field in widget.fields) Padding(padding: const EdgeInsets.only(top: 20),
              child: TextFormField(key: ValueKey('editor-${field.key}'), controller: _controllers[field.key],
                enabled: !_saving, minLines: field.lines, maxLines: field.lines == 1 ? 1 : null,
                keyboardType: field.lines > 1 ? TextInputType.multiline : TextInputType.text,
                textCapitalization: TextCapitalization.none, onChanged: _changed,
                decoration: InputDecoration(labelText: field.label, helperText: field.hint),
                validator: (value) => field.required && (value == null || value.trim().isEmpty) ? '此欄位必填' : null)),
          ],
        )),
      ))),
  );
}
