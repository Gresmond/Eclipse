import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import '../app_state.dart';

void goTo(String url) => web.window.location.assign(url);
void reloadPage() => web.window.location.reload();
void openTab(String url) => web.window.open(url, '_blank', 'noopener');

/// Calls [callback] when the page hides or starts unloading so browser writes
/// can flush promptly. Returns a function to remove the listeners.
void Function() onPageLeave(void Function() callback) {
  final onHide = ((web.Event _) => callback()).toJS;
  final onVis = ((web.Event _) {
    if (web.document.visibilityState == 'hidden') callback();
  }).toJS;
  web.window.addEventListener('pagehide', onHide);
  web.document.addEventListener('visibilitychange', onVis);
  return () {
    web.window.removeEventListener('pagehide', onHide);
    web.document.removeEventListener('visibilitychange', onVis);
  };
}

void Function() browserPreferences(AppState state) {
  final scheme = web.window.matchMedia('(prefers-color-scheme: dark)');
  state.nightLightAvailable = true;
  state.nightLightIs(scheme.matches);
  final onScheme = ((web.Event _) => state.nightLightIs(scheme.matches)).toJS;
  final onLeave = ((web.BeforeUnloadEvent event) {
    final sync = state.sync;
    if (!state.closing && sync != null && sync.isOn && (state.hasJournalDraft(state.shownDay) || sync.hasPendingChanges)) {
      event.preventDefault();
      event.returnValue = ' ';
    }
  }).toJS;
  scheme.addEventListener('change', onScheme);
  web.window.addEventListener('beforeunload', onLeave);
  return () {
    scheme.removeEventListener('change', onScheme);
    web.window.removeEventListener('beforeunload', onLeave);
  };
}

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
    final id = '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';
    final channel = web.BroadcastChannel(_name);
    channel.postMessage(id.toJS);
    final held = Completer<void>();
    final release = Completer<void>();
    final repeat = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!held.isCompleted) channel.postMessage(id.toJS);
    });
    web.window.navigator.locks.request(
      _name,
      ((web.Lock? _) {
        repeat.cancel();
        held.complete();
        return release.future.toJS;
      }).toJS,
    );
    await held.future;
    // Listens only once it's the holder, ignoring repeats from our own request.
    channel.onmessage = ((web.MessageEvent event) {
      final sender = event.data;
      if (sender != null && sender.isA<JSString>() && (sender as JSString).toDart == id) return;
      onAsked();
    }).toJS;
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
    try {
      final shown = web.Notification(alert.text, web.NotificationOptions(body: body, tag: alert.uid));
      shown.onclick = ((web.Event _) {
        web.window.focus();
        shown.close();
        _open?.call(alert.uid);
      }).toJS;
    } catch (_) {
      // Mobile browsers disallow direct Notification construction outside SWs.
    }
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
    try {
      await web.Notification.requestPermission().toDart;
    } catch (_) {
      // Permission API unavailable or blocked by the browser.
    }
  }
}
