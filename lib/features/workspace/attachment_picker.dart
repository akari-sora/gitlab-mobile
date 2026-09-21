import 'dart:typed_data';
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
    return readLimitedAttachment(
      filename: _basename(file.name, 'image.jpg'),
      length: length,
      open: () => file.openRead().map<List<int>>((chunk) => chunk),
      contentType: file.mimeType,
    );
  }

  @override
  Future<PickedAttachment?> pickFile() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    // lengthSync is metadata. Null means unknown; PlatformFile.length() can
    // read the whole file, so the capped stream is the size check.
    return readLimitedAttachment(
      filename: _basename(file.name, 'file'),
      length: file.lengthSync(),
      open: () => file.readAsByteStream().map<List<int>>((chunk) => chunk),
      contentType: file.xFile.mimeType,
    );
  }
}

Future<PickedAttachment> readLimitedAttachment({
  required String filename,
  required int? length,
  required Stream<List<int>> Function() open,
  String? contentType,
}) async {
  if (length != null && length > GitLabApi.maxUploadBytes) {
    throw const ApiFailure(FailureKind.attachmentTooLarge);
  }
  final bytes = await _readCapped(open(), GitLabApi.maxUploadBytes);
  return PickedAttachment(filename: filename, bytes: bytes, contentType: contentType);
}

Future<Uint8List> _readCapped(Stream<List<int>> bytes, int maxBytes) async {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in bytes) {
    if (chunk.length > maxBytes - total) {
      throw const ApiFailure(FailureKind.attachmentTooLarge);
    }
    builder.add(chunk);
    total += chunk.length;
  }
  return builder.takeBytes();
}

String _basename(String name, String fallback) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return fallback;
  final base = trimmed.split(RegExp(r'[\\/]')).last.trim();
  return base.isEmpty ? fallback : base;
}
