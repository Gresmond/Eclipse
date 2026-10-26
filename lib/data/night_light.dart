import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Whether Hyprland's night light is on, asked of hyprsunset over its
/// socket (what `hyprctl hyprsunset temperature` does, without the process).
class NightLight {
  NightLight(this.socketPath);

  /// Null outside a Hyprland session.
  static NightLight? forSession() {
    final env = Platform.environment;
    final runtime = env['XDG_RUNTIME_DIR'], instance = env['HYPRLAND_INSTANCE_SIGNATURE'];
    if (runtime == null || instance == null) return null;
    return NightLight('$runtime/hypr/$instance/.hyprsunset.sock');
  }

  final String socketPath;

  /// The temperature hyprsunset sits at with night light off; Quickshell's
  /// toggle sets exactly this when switching it off.
  static const offTemperature = 6000;

  /// Null when hyprsunset isn't running or doesn't answer.
  Future<bool?> isOn() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(seconds: 1));
      socket.write('temperature');
      // hyprsunset answers but leaves the connection open, so take the
      // first reply rather than waiting for it to close.
      final reply = await utf8.decoder.bind(socket).first.timeout(const Duration(seconds: 1));
      final temperature = int.tryParse(reply.trim());
      return temperature == null ? null : temperature != offTemperature;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }
}
