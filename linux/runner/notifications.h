#ifndef RUNNER_NOTIFICATIONS_H_
#define RUNNER_NOTIFICATIONS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Shows reminders as desktop notifications (org.freedesktop.Notifications,
// as served by Quickshell, KDE, GNOME, mako, dunst and others), over the
// "eclipse/notifications" channel. Clicking one brings [window] up and tells
// the app which task it was for.
void notifications_start(GtkWindow* window, FlView* view);

#endif  // RUNNER_NOTIFICATIONS_H_
