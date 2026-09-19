import '../../core/models.dart';
final class FileArgs {
  const FileArgs(this.project, this.sha, this.path);
  final Project project;
  final String sha;
  final String path;
}
