#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// A window that hosts a Flutter view, with an icon in the notification area.
// Closing the window only hides it, so Eclipse keeps running and syncing; the
// icon brings it back, and its menu quits (as the tray does on Linux).
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Posted by a second copy of the app, to bring this one's window up.
  static UINT ShowMessage();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  void AddTrayIcon();
  void ShowTrayMenu(int x, int y);
  void ShowTrayHintOnce();
  // A reminder, as a toast from the notification-area icon.
  void ShowReminder(const std::string& key, const std::string& title,
                    const std::string& body);
  void ToggleWindow();
  void ShowAndFocus();

  // Asks the app to save and close, then closes the window.
  void Quit();

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "quit" goes to the app over this, as on Linux.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> lifecycle_;

  // The app asks for a folder over this.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> folders_;

  // Reminders come over this, and a click on one goes back.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      notifications_;

  // The task the toast showing is for; empty for the tray hint. Windows
  // shows one at a time from an icon.
  std::string reminder_key_;

  NOTIFYICONDATA tray_{};
  bool quitting_ = false;

  // When the window last lost focus: clicking the icon takes it, so a click
  // just after counts as on a focused window, which it hides.
  ULONGLONG deactivated_at_ = 0;

  // Sent when Explorer restarts, which forgets every icon.
  const UINT taskbar_created_ = RegisterWindowMessage(L"TaskbarCreated");
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
