import 'dart:io';

/// Replaces the file at [path] with what [write] puts in the file beside it,
/// renamed into place once written, so a crash never leaves half a file.
Future<void> replaceSafely(String path, Future<void> Function(File part) write) async {
  final part = File('$path.part');
  await write(part);
  await part.rename(path);
}

/// As [replaceSafely], without waiting. A part left by a crash is removed
/// first, for writers that can't write over one.
void replaceSafelySync(String path, void Function(File part) write) {
  final part = File('$path.part');
  if (part.existsSync()) part.deleteSync();
  write(part);
  part.renameSync(path);
}
