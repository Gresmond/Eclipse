#ifndef RUNNER_TRAY_H_
#define RUNNER_TRAY_H_

#include <gtk/gtk.h>
#include <flutter_linux/flutter_linux.h>

// Puts Eclipse in the system tray (StatusNotifierItem, as used by Quickshell,
// Waybar, KDE and others) for as long as the app runs, open or not. Clicking
// it shows or hides [window]; its menu can also quit, which closing the
// window no longer does.
void tray_start(GtkApplication* app, GtkWindow* window, FlView* view);

// Shows [window], mapped afresh so window rules (the scratchpad) apply.
void tray_show_window(GtkWindow* window);

#endif  // RUNNER_TRAY_H_
