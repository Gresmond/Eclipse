#include "tray.h"

#include <libdbusmenu-glib/menuitem.h>
#include <libdbusmenu-glib/server.h>
#include <unistd.h>

namespace {

constexpr char kItemPath[] = "/StatusNotifierItem";
constexpr char kMenuPath[] = "/MenuBar";
constexpr char kWatcher[] = "org.kde.StatusNotifierWatcher";

constexpr char kIntrospection[] = R"xml(
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconThemePath" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    <signal name="NewIcon"/>
    <signal name="NewStatus"><arg name="status" type="s"/></signal>
  </interface>
</node>)xml";

struct Tray {
  GtkApplication* app;
  GtkWindow* window;
  gchar* bus_name;
  GDBusConnection* connection;
  DbusmenuServer* menu;
  DbusmenuMenuitem* toggle_item;
  FlMethodChannel* lifecycle;
  bool quitting;
};

Tray tray;

// Shown and focused: the click hides it. Otherwise (hidden, or sitting in
// a closed scratchpad) the click brings it up.
void toggle_window() {
  if (gtk_widget_get_visible(GTK_WIDGET(tray.window)) &&
      gtk_window_is_active(tray.window)) {
    gtk_widget_hide(GTK_WIDGET(tray.window));
  } else {
    tray_show_window(tray.window);
  }
}

void update_toggle_label() {
  if (tray.toggle_item == nullptr) return;
  dbusmenu_menuitem_property_set(
      tray.toggle_item, DBUSMENU_MENUITEM_PROP_LABEL,
      gtk_widget_get_visible(GTK_WIDGET(tray.window)) ? "Hide Eclipse"
                                                      : "Show Eclipse");
}

void on_visibility_changed(GtkWidget*, gpointer) { update_toggle_label(); }

void on_toggle_clicked(DbusmenuMenuitem*, guint, gpointer) {
  if (gtk_widget_get_visible(GTK_WIDGET(tray.window))) {
    gtk_widget_hide(GTK_WIDGET(tray.window));
  } else {
    tray_show_window(tray.window);
  }
}

void on_quit_ready(GObject* object, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  if (response == nullptr || !FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    g_warning("Could not save Eclipse before quitting: %s",
              error != nullptr ? error->message : "shutdown was not completed");
    tray.quitting = false;
    return;
  }
  g_application_quit(G_APPLICATION(tray.app));
}

void on_quit_clicked(DbusmenuMenuitem*, guint, gpointer) {
  if (tray.quitting) return;
  tray.quitting = true;
  fl_method_channel_invoke_method(tray.lifecycle, "quit", nullptr, nullptr,
                                  on_quit_ready, nullptr);
}

void build_menu() {
  DbusmenuMenuitem* root = dbusmenu_menuitem_new();

  tray.toggle_item = dbusmenu_menuitem_new();
  g_signal_connect(tray.toggle_item, DBUSMENU_MENUITEM_SIGNAL_ITEM_ACTIVATED,
                   G_CALLBACK(on_toggle_clicked), nullptr);
  dbusmenu_menuitem_child_append(root, tray.toggle_item);
  update_toggle_label();

  DbusmenuMenuitem* separator = dbusmenu_menuitem_new();
  dbusmenu_menuitem_property_set(separator, DBUSMENU_MENUITEM_PROP_TYPE,
                                 "separator");
  dbusmenu_menuitem_child_append(root, separator);

  DbusmenuMenuitem* quit = dbusmenu_menuitem_new();
  dbusmenu_menuitem_property_set(quit, DBUSMENU_MENUITEM_PROP_LABEL,
                                 "Quit Eclipse");
  g_signal_connect(quit, DBUSMENU_MENUITEM_SIGNAL_ITEM_ACTIVATED,
                   G_CALLBACK(on_quit_clicked), nullptr);
  dbusmenu_menuitem_child_append(root, quit);

  tray.menu = dbusmenu_server_new(kMenuPath);
  dbusmenu_server_set_root(tray.menu, root);
  g_object_unref(root);
}

void handle_method(GDBusConnection*, const gchar*, const gchar*, const gchar*,
                   const gchar* method, GVariant*,
                   GDBusMethodInvocation* invocation, gpointer) {
  if (g_strcmp0(method, "Activate") == 0 ||
      g_strcmp0(method, "SecondaryActivate") == 0) {
    toggle_window();
  }
  // ContextMenu and Scroll: the tray shows the menu itself; nothing to scroll.
  g_dbus_method_invocation_return_value(invocation, nullptr);
}

GVariant* handle_property(GDBusConnection*, const gchar*, const gchar*,
                          const gchar*, const gchar* property, GError**,
                          gpointer) {
  if (g_strcmp0(property, "Category") == 0)
    return g_variant_new_string("ApplicationStatus");
  if (g_strcmp0(property, "Id") == 0) return g_variant_new_string("Eclipse");
  if (g_strcmp0(property, "Title") == 0) return g_variant_new_string("Eclipse");
  // Always Active: a Passive item is hidden by trays that filter them.
  if (g_strcmp0(property, "Status") == 0) return g_variant_new_string("Active");
  // Installed into the icon theme by linux/install.sh.
  if (g_strcmp0(property, "IconName") == 0)
    return g_variant_new_string(APPLICATION_ID);
  if (g_strcmp0(property, "IconThemePath") == 0)
    return g_variant_new_string("");
  if (g_strcmp0(property, "ToolTip") == 0) {
    return g_variant_new("(s@a(iiay)ss)", "",
                         g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr,
                                             0),
                         "Eclipse", "Click to show or hide");
  }
  if (g_strcmp0(property, "ItemIsMenu") == 0)
    return g_variant_new_boolean(FALSE);
  if (g_strcmp0(property, "Menu") == 0)
    return g_variant_new_object_path(kMenuPath);
  return nullptr;
}

const GDBusInterfaceVTable kVtable = {handle_method, handle_property, nullptr,
                                      {nullptr}};

void register_with_watcher() {
  if (tray.connection == nullptr) return;
  g_dbus_connection_call(tray.connection, kWatcher, "/StatusNotifierWatcher",
                         kWatcher, "RegisterStatusNotifierItem",
                         g_variant_new("(s)", tray.bus_name), nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
}

// The tray (the watcher) may start after Eclipse, or restart with the
// shell; register again each time it appears.
void on_watcher_appeared(GDBusConnection*, const gchar*, const gchar*,
                         gpointer) {
  register_with_watcher();
}

void on_bus_acquired(GDBusConnection* connection, const gchar*, gpointer) {
  tray.connection = connection;
  g_autoptr(GDBusNodeInfo) info =
      g_dbus_node_info_new_for_xml(kIntrospection, nullptr);
  g_dbus_connection_register_object(connection, kItemPath,
                                    info->interfaces[0], &kVtable, nullptr,
                                    nullptr, nullptr);
  build_menu();
  g_bus_watch_name_on_connection(connection, kWatcher,
                                 G_BUS_NAME_WATCHER_FLAGS_NONE,
                                 on_watcher_appeared, nullptr, nullptr,
                                 nullptr);
}

}  // namespace

void tray_show_window(GtkWindow* window) {
  // A window left mapped in a closed scratchpad is "visible" but unseen;
  // hiding first makes showing map it again, so the scratchpad rule opens it.
  if (gtk_widget_get_visible(GTK_WIDGET(window)) &&
      !gtk_window_is_active(window)) {
    gtk_widget_hide(GTK_WIDGET(window));
  }
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_present(window);
}

void tray_start(GtkApplication* app, GtkWindow* window, FlView* view) {
  tray.app = app;
  tray.window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  tray.lifecycle = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "eclipse/lifecycle", FL_METHOD_CODEC(codec));
  g_signal_connect(window, "show", G_CALLBACK(on_visibility_changed), nullptr);
  g_signal_connect(window, "hide", G_CALLBACK(on_visibility_changed), nullptr);
  tray.bus_name =
      g_strdup_printf("org.kde.StatusNotifierItem-%d-1", getpid());
  g_bus_own_name(G_BUS_TYPE_SESSION, tray.bus_name, G_BUS_NAME_OWNER_FLAGS_NONE,
                 on_bus_acquired, nullptr, nullptr, nullptr, nullptr);
}
