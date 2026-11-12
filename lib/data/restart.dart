import 'dart:io';

/// Starts the replacement only after this process releases its single-instance
/// registration. Both folder changes and installed updates use this path.
Future<void> restartApplication({required Future<void> Function() beforeRestart, String? executable}) async {
  // Arrange the replacement before closing the database, so failure to start
  // the shell leaves the current application usable.
  final target = executable ?? Platform.resolvedExecutable;
  final replacement = await Process.start('sh', [
    '-c',
    'while kill -0 $pid 2>/dev/null; do sleep 0.1; done; exec "\$0"',
    target,
  ], mode: ProcessStartMode.detached);
  try {
    await beforeRestart();
  } catch (_) {
    replacement.kill();
    rethrow;
  }
  exit(0);
}
