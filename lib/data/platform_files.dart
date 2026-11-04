import 'dart:io';

/// Opens a URL or folder with the operating system's default application.
Future<void> openExternal(String target) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', [target], mode: ProcessStartMode.detached);
  } else {
    await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [target]);
  }
}

/// Shows [file] in the file manager, selected once it exists: Dolphin here,
/// never xdg-open first, which can open a terminal instead.
Future<void> showInFiles(File file) async {
  var folder = file.parent;
  try {
    await folder.create(recursive: true);
  } on FileSystemException {
    // The folder can't be made: show the nearest one that's there instead.
    while (!folder.existsSync() && folder.parent.path != folder.path) {
      folder = folder.parent;
    }
  }
  final exists = file.existsSync();
  if (Platform.isMacOS) {
    await Process.run('open', exists ? ['-R', file.path] : [folder.path]);
  } else if (Platform.isWindows) {
    // Separate arguments: a path with a space gets quoted, and Explorer
    // only reads /select, before the quotes, not inside them.
    await Process.start(
      'explorer.exe',
      exists ? ['/select,', file.path] : [folder.path],
      mode: ProcessStartMode.detached,
    );
  } else {
    // Detached: Dolphin keeps running after it opens, and on its own.
    try {
      await Process.start('dolphin', exists ? ['--select', file.path] : [folder.path], mode: ProcessStartMode.detached);
    } on ProcessException {
      await Process.start('xdg-open', [folder.path], mode: ProcessStartMode.detached);
    }
  }
}
