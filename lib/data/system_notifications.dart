import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

/// Reminders as the system's own notifications, over the runner's channel:
/// the freedesktop notification service on Linux, the notification area's
/// toast on Windows, Notification Centre on a Mac. Clicking one brings the
/// window up, and the runner says which.
class SystemNotifications implements ReminderNotifier {
  SystemNotifications() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'clicked') throw MissingPluginException();
      final uid = (call.arguments as Map?)?['key'];
      if (uid is String) _open?.call(uid);
    });
  }

  static const _channel = MethodChannel('eclipse/notifications');

  void Function(String uid)? _open;

  @override
  set onOpen(void Function(String uid)? open) => _open = open;

  @override
  void show(ReminderAlert alert, String body) {
    _channel
        .invokeMethod<void>('show', {'key': alert.uid, 'title': alert.text, 'body': body})
        .catchError((Object error) => debugPrint('Could not show a notification: $error'));
  }
}
