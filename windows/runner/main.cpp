#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One copy at a time, as on Linux and Mac: opening Eclipse again brings up
  // the running copy's window, even from the tray. The mutex goes with this
  // process, so a restart's new copy waits for the old one to exit first.
  ::CreateMutex(nullptr, FALSE, L"Local\\dev.nicholas.productivity_app");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = ::FindWindow(Win32Window::kClassName, nullptr);
    if (running != nullptr) {
      DWORD process = 0;
      ::GetWindowThreadProcessId(running, &process);
      // Lets the running copy come to the front.
      ::AllowSetForegroundWindow(process);
      ::PostMessage(running, FlutterWindow::ShowMessage(), 0, 0);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  // As on Linux: the layout needs at least this much room.
  window.SetMinimumSize(Win32Window::Size(750, 500));
  if (!window.Create(L"Eclipse", origin, size)) {
    return EXIT_FAILURE;
  }
  // Closing only hides the window; Quit in the tray menu destroys it.
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
