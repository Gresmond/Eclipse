import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

/// Reminders as the system's own notifications, over the runner's channel:
/// the freedesktop notification service. Clicking one brings the window up,
/// and the runner says which.
class SystemNotifications implements ReminderNotifier, ReminderActions {
  SystemNotifications() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'clicked') throw MissingPluginException();
      final uid = (call.arguments as Map?)?['key'];
      if (uid is! String) return;
      final action = (call.arguments as Map)['action'];
      if (action == 'snooze' || action == 'done') {
        onAction?.call(uid, action as String);
      } else {
        _open?.call(uid.split('|').first);
      }
    });
  }

  static const _channel = MethodChannel('eclipse/notifications');

  @override
  void Function(String, String)? onAction;
  void Function(String uid)? _open;

  @override
  set onOpen(void Function(String uid)? open) => _open = open;

  @override
  void show(ReminderAlert alert, String body) {
    _channel
        .invokeMethod<void>('show', {'key': alert.key, 'title': alert.text, 'body': body})
        .catchError((Object error) => debugPrint('Could not show a notification: $error'));
  }
}
