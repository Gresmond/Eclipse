import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../app_state.dart';

void goTo(String url) => web.window.location.assign(url);
void reloadPage() => web.window.location.reload();
void openTab(String url) => web.window.open(url, '_blank', 'noopener');

/// A small note kept in this browser; storage that's blocked keeps nothing.
String? remembered(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void remember(String key, String? value) {
  try {
    value == null ? web.window.localStorage.removeItem(key) : web.window.localStorage.setItem(key, value);
  } catch (_) {
    // Only a convenience.
  }
}

/// Only one tab has the data at a time, as nothing else would stop two
/// overwriting each other. A new tab asks for it, and the one holding it lets
/// go when [onAsked] has saved everything.
class DataLock {
  DataLock._(this._release, this._channel);

  static const _name = 'eclipse-data';

  static Future<DataLock> take({required void Function() onAsked}) async {
    final channel = web.BroadcastChannel(_name);
    channel.postMessage('wanted'.toJS);
    final held = Completer<void>();
    final release = Completer<void>();
    web.window.navigator.locks.request(
      _name,
      ((web.Lock? _) {
        held.complete();
        return release.future.toJS;
      }).toJS,
    );
    await held.future;
    // Listens only once it's the holder: a request of its own never reaches it,
    // and one sent while it waited was for the tab before it.
    channel.onmessage = ((web.MessageEvent _) => onAsked()).toJS;
    return DataLock._(release, channel);
  }

  final Completer<void> _release;
  final web.BroadcastChannel _channel;

  void release() {
    _channel.close();
    if (!_release.isCompleted) _release.complete();
  }
}

/// Reminders as the browser's notifications. They go off only while a tab
/// has Eclipse open.
class BrowserNotifications implements ReminderNotifier, ReminderPermission {
  void Function(String uid)? _open;

  @override
  set onOpen(void Function(String uid)? open) => _open = open;

  @override
  void show(ReminderAlert alert, String body) {
    if (access != ReminderAccess.allowed) return;
    final shown = web.Notification(alert.text, web.NotificationOptions(body: body, tag: alert.uid));
    shown.onclick = ((web.Event _) {
      web.window.focus();
      shown.close();
      _open?.call(alert.uid);
    }).toJS;
  }

  @override
  ReminderAccess get access {
    try {
      return switch (web.Notification.permission) {
        'granted' => ReminderAccess.allowed,
        'denied' => ReminderAccess.blocked,
        _ => ReminderAccess.notAsked,
      };
    } catch (_) {
      return ReminderAccess.blocked;
    }
  }

  @override
  Future<void> ask() async {
    await web.Notification.requestPermission().toDart;
  }
}
