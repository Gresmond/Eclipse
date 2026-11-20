import '../app_state.dart';

Never _no() => throw UnsupportedError('Not in a browser');

void goTo(String url) => _no();
void reloadPage() => _no();
void openTab(String url) => _no();
void Function() onPageLeave(void Function() callback) => _no();
void Function() browserPreferences(AppState state, bool Function() hasPendingWrite) => _no();
String? remembered(String key) => _no();
void remember(String key, String? value) => _no();

class DataLock {
  static Future<DataLock> take({required void Function() onAsked}) => _no();
  void release() => _no();
}

class BrowserNotifications implements ReminderNotifier, ReminderPermission {
  @override
  void show(ReminderAlert alert, String body) => _no();
  @override
  set onOpen(void Function(String uid)? open) => _no();
  @override
  ReminderAccess get access => _no();
  @override
  Future<void> ask() => _no();
}
