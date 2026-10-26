#include "flutter_window.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <windowsx.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
// Closes the window once the app has saved, outside the engine's callback.
constexpr UINT kQuitMessage = WM_APP + 2;

constexpr UINT kToggleCommand = 1;
constexpr UINT kQuitCommand = 2;

// Remembers that the "still running" notification has been shown.
constexpr wchar_t kSettingsKey[] = L"Software\\Eclipse";
constexpr wchar_t kTrayHintValue[] = L"TrayHintShown";

std::wstring Utf16FromUtf8(const std::string& utf8) {
  const int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()),
                                         nullptr, 0);
  std::wstring utf16(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      utf16.data(), length);
  return utf16;
}

std::string StringArgument(const flutter::EncodableValue* arguments,
                           const char* key) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return std::string();
  auto entry = map->find(flutter::EncodableValue(key));
  if (entry == map->end()) return std::string();
  const auto* value = std::get_if<std::string>(&entry->second);
  return value == nullptr ? std::string() : *value;
}

// Explorer's own folder picker, owned by |owner| so it stays in front of it.
// Empty when cancelled.
std::string PickFolder(HWND owner, const std::string& title,
                       const std::string& start) {
  IFileOpenDialog* dialog = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
    return std::string();
  }
  DWORD options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
  dialog->SetTitle(Utf16FromUtf8(title).c_str());
  IShellItem* folder = nullptr;
  if (!start.empty() &&
      SUCCEEDED(SHCreateItemFromParsingName(Utf16FromUtf8(start).c_str(),
                                            nullptr, IID_PPV_ARGS(&folder)))) {
    dialog->SetFolder(folder);
    folder->Release();
  }
  std::string path;
  IShellItem* picked = nullptr;
  if (SUCCEEDED(dialog->Show(owner)) && SUCCEEDED(dialog->GetResult(&picked))) {
    PWSTR name = nullptr;
    if (SUCCEEDED(picked->GetDisplayName(SIGDN_FILESYSPATH, &name))) {
      path = Utf8FromUtf16(name);
      CoTaskMemFree(name);
    }
    picked->Release();
  }
  dialog->Release();
  return path;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

// static
UINT FlutterWindow::ShowMessage() {
  static const UINT message =
      RegisterWindowMessage(L"dev.nicholas.productivity_app.show");
  return message;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  lifecycle_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "eclipse/lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
  AddTrayIcon();

  folders_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "eclipse/folders",
      &flutter::StandardMethodCodec::GetInstance());
  folders_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "pick") {
          result->NotImplemented();
          return;
        }
        const std::string path =
            PickFolder(GetHandle(), StringArgument(call.arguments(), "title"),
                       StringArgument(call.arguments(), "start"));
        if (path.empty()) {
          result->Success();
        } else {
          result->Success(flutter::EncodableValue(path));
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_.hWnd != nullptr) {
    Shell_NotifyIcon(NIM_DELETE, &tray_);
    DestroyIcon(tray_.hIcon);
    tray_.hWnd = nullptr;
  }
  lifecycle_ = nullptr;
  folders_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Before Flutter, which would otherwise treat closing as quitting.
  switch (message) {
    case WM_CLOSE:
      ShowWindow(hwnd, SW_HIDE);
      ShowTrayHintOnce();
      return 0;
    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
          ToggleWindow();
          break;
        case WM_CONTEXTMENU:
          ShowTrayMenu(GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam));
          break;
      }
      return 0;
    case kQuitMessage:
      DestroyWindow(hwnd);
      return 0;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) deactivated_at_ = GetTickCount64();
      break;
    case WM_ENDSESSION:
      // Signing out, shutting down, or the installer closing the app to
      // update it.
      if (wparam) Quit();
      break;
  }
  if (message == ShowMessage()) {
    ShowAndFocus();
    return 0;
  }
  if (message == taskbar_created_) {
    AddTrayIcon();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  if (tray_.hWnd == nullptr) {
    tray_.cbSize = sizeof(tray_);
    tray_.hWnd = GetHandle();
    tray_.uID = 1;
    tray_.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE | NIF_SHOWTIP;
    tray_.uCallbackMessage = kTrayMessage;
    tray_.hIcon = static_cast<HICON>(LoadImage(
        GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
    wcscpy_s(tray_.szTip, L"Eclipse");
    tray_.uVersion = NOTIFYICON_VERSION_4;
  }
  Shell_NotifyIcon(NIM_ADD, &tray_);
  Shell_NotifyIcon(NIM_SETVERSION, &tray_);
}

void FlutterWindow::ShowTrayMenu(int x, int y) {
  HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  AppendMenu(menu, MF_STRING, kToggleCommand,
             IsWindowVisible(hwnd) ? L"Hide Eclipse" : L"Show Eclipse");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kQuitCommand, L"Quit Eclipse");
  // Without this the menu stays open when clicking elsewhere.
  SetForegroundWindow(hwnd);
  const UINT command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, x,
                     y, 0, hwnd, nullptr);
  DestroyMenu(menu);
  if (command == kToggleCommand) {
    if (IsWindowVisible(hwnd)) {
      ShowWindow(hwnd, SW_HIDE);
    } else {
      ShowAndFocus();
    }
  } else if (command == kQuitCommand) {
    Quit();
  }
}

// Once ever: closing it the first time says where it went.
void FlutterWindow::ShowTrayHintOnce() {
  DWORD shown = 0;
  DWORD size = sizeof(shown);
  if (RegGetValue(HKEY_CURRENT_USER, kSettingsKey, kTrayHintValue,
                  RRF_RT_REG_DWORD, nullptr, &shown, &size) == ERROR_SUCCESS &&
      shown != 0) {
    return;
  }
  NOTIFYICONDATA hint = tray_;
  hint.uFlags = NIF_INFO;
  hint.dwInfoFlags = NIIF_NONE;
  wcscpy_s(hint.szInfoTitle, L"Eclipse is still running");
  wcscpy_s(hint.szInfo,
           L"It keeps syncing in the background. Click its icon by the clock "
           L"(it may be under ^) to open it, or right-click it to quit.");
  Shell_NotifyIcon(NIM_MODIFY, &hint);
  shown = 1;
  RegSetKeyValue(HKEY_CURRENT_USER, kSettingsKey, kTrayHintValue, REG_DWORD,
                 &shown, sizeof(shown));
}

// Shown and focused: the click hides it. Otherwise (hidden, minimised, or
// behind other windows) the click brings it up.
void FlutterWindow::ToggleWindow() {
  HWND hwnd = GetHandle();
  const bool shown = IsWindowVisible(hwnd) && !IsIconic(hwnd);
  const bool focused = GetForegroundWindow() == hwnd ||
                       GetTickCount64() - deactivated_at_ < 500;
  if (shown && focused) {
    ShowWindow(hwnd, SW_HIDE);
  } else {
    ShowAndFocus();
  }
}

void FlutterWindow::ShowAndFocus() {
  HWND hwnd = GetHandle();
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::Quit() {
  if (quitting_ || !lifecycle_) return;
  quitting_ = true;
  HWND hwnd = GetHandle();
  lifecycle_->InvokeMethod(
      "quit", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [hwnd](const flutter::EncodableValue*) {
            PostMessage(hwnd, kQuitMessage, 0, 0);
          },
          [this](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { quitting_ = false; },
          [this]() { quitting_ = false; }));
}
