import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';

class PickedAttachment {
  const PickedAttachment({required this.filename, required this.bytes, this.contentType});
  final String filename;
  final List<int> bytes;
  final String? contentType;
}

abstract interface class AttachmentPicker {
  Future<PickedAttachment?> pickImage();
  Future<PickedAttachment?> pickFile();
}

final class PluginAttachmentPicker implements AttachmentPicker {
  const PluginAttachmentPicker();

  @override
  Future<PickedAttachment?> pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, requestFullMetadata: false);
    if (file == null) return null;
    final length = await file.length();
    return _limited(
      filename: _basename(file.name, 'image.jpg'),
      length: length,
      read: file.readAsBytes,
      contentType: file.mimeType,
    );
  }

  @override
  Future<PickedAttachment?> pickFile() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    return _limited(
      filename: _basename(file.name, 'file'),
      length: file.lengthSync() ?? await file.length(),
      read: file.readAsBytes,
      contentType: file.xFile.mimeType,
    );
  }
}

Future<PickedAttachment> _limited({
  required String filename,
  required int? length,
  required Future<List<int>> Function() read,
  String? contentType,
}) async {
  if (length != null && length > GitLabApi.maxUploadBytes) {
    throw const ApiFailure(FailureKind.tooLarge);
  }
  final bytes = await read();
  if (bytes.length > GitLabApi.maxUploadBytes) {
    throw const ApiFailure(FailureKind.tooLarge);
  }
  return PickedAttachment(filename: filename, bytes: bytes, contentType: contentType);
}

String _basename(String name, String fallback) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return fallback;
  final base = trimmed.split(RegExp(r'[\\/]')).last.trim();
  return base.isEmpty ? fallback : base;
}
