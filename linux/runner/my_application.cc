#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "tray.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The one window, kept (just hidden) when it's closed.
  GtkWindow* window;
  // Started with --background (at login): run, but don't show the window
  // until the app is opened.
  gboolean background;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  if (self->background) return;
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Closing the window only hides it, so the app keeps running (and keeps
// checking for updates) and opens again instantly.
static gboolean delete_event_cb(GtkWidget* window, GdkEvent* event,
                                gpointer user_data) {
  gtk_widget_hide(window);
  return TRUE;
}

// Implements GApplication::activate. Opening the app again while it runs
// lands here in the running copy.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    self->background = FALSE;
    tray_show_window(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event_cb),
                   nullptr);

  // No title bar: the app's own header is the top of the window. The title
  // still names the window in task switchers and window lists.
  gtk_window_set_title(window, "Eclipse");
  gtk_window_set_decorated(window, FALSE);
  // Installed by linux/install.sh under the application ID.
  gtk_window_set_icon_name(window, APPLICATION_ID);

  gtk_window_set_default_size(window, 1440, 900);
  gtk_widget_set_size_request(GTK_WIDGET(window), 750, 500);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);
  // Impeller's OpenGL backend leaves gradient-filled shapes (selected tabs,
  // ticked cells) with jagged, un-antialiased edges. Skia draws them smoothly.
  fl_dart_project_set_enable_impeller(project, FALSE);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  tray_start(GTK_APPLICATION(application), window, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  self->background =
      g_strv_contains((const gchar* const*)*arguments, "--background");

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // Ubuntu 22.04 has GLib 2.72. The renamed flag appeared in 2.74;
  // both names mean zero flags and retain single-instance behaviour.
#if GLIB_CHECK_VERSION(2, 74, 0)
  constexpr auto flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  constexpr auto flags = G_APPLICATION_FLAGS_NONE;
#endif

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
