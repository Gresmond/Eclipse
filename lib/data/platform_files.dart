import 'dart:io';

/// Opens a URL or folder with the operating system's default application.
Future<void> openExternal(String target) async {
  if (Platform.isWindows) {
    await Process.start('explorer.exe', [target], mode: ProcessStartMode.detached);
  } else {
    await Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [target]);
  }
}
