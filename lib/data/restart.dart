import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Starts the replacement only after this process releases its single-instance
/// registration. Both folder changes and installed updates use this path.
Future<void> restartApplication({required Future<void> Function() beforeRestart, String? executable}) async {
  // Arrange the replacement before closing the database, so failure to start
  // the shell leaves the current application usable.
  final target = executable ?? Platform.resolvedExecutable;
  final Process replacement;
  if (Platform.isWindows) {
    final path = target.replaceAll("'", "''");
    final script = "Wait-Process -Id $pid -ErrorAction SilentlyContinue; Start-Process -FilePath '$path'";
    final bytes = ByteData(script.length * 2);
    for (var i = 0; i < script.length; i++) {
      bytes.setUint16(i * 2, script.codeUnitAt(i), Endian.little);
    }
    replacement = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      base64Encode(bytes.buffer.asUint8List()),
    ], mode: ProcessStartMode.detached);
  } else {
    replacement = await Process.start('sh', [
      '-c',
      'while kill -0 $pid 2>/dev/null; do sleep 0.1; done; exec "\$0"',
      target,
    ], mode: ProcessStartMode.detached);
  }
  try {
    await beforeRestart();
  } catch (_) {
    replacement.kill();
    rethrow;
  }
  exit(0);
}
