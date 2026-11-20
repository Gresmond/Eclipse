#include "notifications.h"

#include "tray.h"

namespace {

constexpr char kService[] = "org.freedesktop.Notifications";
constexpr char kPath[] = "/org/freedesktop/Notifications";

struct Notifications {
  GtkWindow* window;
  FlMethodChannel* channel;
  GDBusConnection* connection;
  // The task each notification shown is for, by the server's id.
  GHashTable* keys;
  // Recently closed notification keys kept briefly for Wayland daemons that
  // emit NotificationClosed right before ActionInvoked.
  GHashTable* closed_keys;
  GHashTable* closed_timers;
  GCancellable* cancellable;
  guint action_sub_id;
  guint closed_sub_id;
};

Notifications notifications;

const gchar* lookup_string(FlValue* args, const char* name) {
  FlValue* value = fl_value_lookup_string(args, name);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : "";
}

void on_shown(GObject* source, GAsyncResult* result, gpointer data) {
  g_autofree gchar* key = static_cast<gchar*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, &error);
  if (reply == nullptr) {
    if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
      g_warning("Could not show a notification: %s", error->message);
    }
    return;
  }
  if (notifications.keys == nullptr) return;
  guint32 id = 0;
  g_variant_get(reply, "(u)", &id);
  g_hash_table_insert(notifications.keys, GUINT_TO_POINTER(id),
                      g_steal_pointer(&key));
}

void show(const gchar* key, const gchar* title, const gchar* body) {
  if (notifications.connection == nullptr) return;
  GVariantBuilder actions;
  g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
  // The click on the notification itself.
  g_variant_builder_add(&actions, "s", "default");
  g_variant_builder_add(&actions, "s", "Open");
  g_variant_builder_add(&actions, "s", "snooze");
  g_variant_builder_add(&actions, "s", "Snooze 10 min");
  g_variant_builder_add(&actions, "s", "done");
  g_variant_builder_add(&actions, "s", "Mark done");
  GVariantBuilder hints;
  g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
  // Installed by linux/install.sh under the application ID.
  g_variant_builder_add(&hints, "{sv}", "desktop-entry",
                        g_variant_new_string(APPLICATION_ID));
  g_variant_builder_add(&hints, "{sv}", "urgency", g_variant_new_byte(1));
  g_dbus_connection_call(
      notifications.connection, kService, kPath, kService, "Notify",
      g_variant_new("(susssasa{sv}i)", "Eclipse", 0, APPLICATION_ID, title,
                    body, &actions, &hints, -1),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, -1,
      notifications.cancellable, on_shown, g_strdup(key));
}

void cancel_closed_timer(guint32 id) {
  if (notifications.closed_timers == nullptr) return;
  gpointer timer_ptr =
      g_hash_table_lookup(notifications.closed_timers, GUINT_TO_POINTER(id));
  if (timer_ptr != nullptr) {
    g_source_remove(GPOINTER_TO_UINT(timer_ptr));
    g_hash_table_remove(notifications.closed_timers, GUINT_TO_POINTER(id));
  }
}

gboolean on_closed_grace_expired(gpointer data) {
  if (notifications.closed_timers != nullptr) {
    g_hash_table_remove(notifications.closed_timers, data);
  }
  if (notifications.closed_keys != nullptr) {
    g_hash_table_remove(notifications.closed_keys, data);
  }
  return G_SOURCE_REMOVE;
}

void on_action(GDBusConnection*, const gchar*, const gchar*, const gchar*,
               const gchar*, GVariant* parameters, gpointer) {
  if (parameters == nullptr ||
      !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(us)"))) {
    return;
  }
  guint32 id = 0;
  const gchar* action = nullptr;
  g_variant_get(parameters, "(u&s)", &id, &action);
  const gchar* key = nullptr;
  if (notifications.keys != nullptr) {
    key = static_cast<const gchar*>(
        g_hash_table_lookup(notifications.keys, GUINT_TO_POINTER(id)));
  }
  if (key == nullptr && notifications.closed_keys != nullptr) {
    key = static_cast<const gchar*>(
        g_hash_table_lookup(notifications.closed_keys, GUINT_TO_POINTER(id)));
  }
  if (key == nullptr || notifications.channel == nullptr) return;
  if (g_strcmp0(action, "default") == 0) tray_show_window(notifications.window);
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "action", fl_value_new_string(action));
  fl_value_set_string_take(args, "key", fl_value_new_string(key));
  fl_method_channel_invoke_method(notifications.channel, "clicked", args,
                                  nullptr, nullptr, nullptr);
}

void on_closed(GDBusConnection*, const gchar*, const gchar*, const gchar*,
               const gchar*, GVariant* parameters, gpointer) {
  if (parameters == nullptr ||
      !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(uu)"))) {
    return;
  }
  guint32 id = 0;
  guint32 reason = 0;
  g_variant_get(parameters, "(uu)", &id, &reason);
  if (notifications.keys == nullptr) return;
  gpointer stolen_key = nullptr;
  if (g_hash_table_steal_extended(notifications.keys, GUINT_TO_POINTER(id),
                                  nullptr, &stolen_key)) {
    if (notifications.closed_keys != nullptr &&
        notifications.closed_timers != nullptr) {
      cancel_closed_timer(id);
      g_hash_table_insert(notifications.closed_keys, GUINT_TO_POINTER(id),
                          stolen_key);
      guint timer = g_timeout_add_seconds(5, on_closed_grace_expired,
                                          GUINT_TO_POINTER(id));
      g_hash_table_insert(notifications.closed_timers, GUINT_TO_POINTER(id),
                          GUINT_TO_POINTER(timer));
    } else {
      g_free(stolen_key);
    }
  }
}

void remove_timer(gpointer, gpointer value, gpointer) {
  g_source_remove(GPOINTER_TO_UINT(value));
}

void on_method(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (g_strcmp0(fl_method_call_get_name(call), "show") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    fl_method_call_respond_error(call, "bad-args", "Expected a map", nullptr,
                                 nullptr);
    return;
  }
  show(lookup_string(args, "key"), lookup_string(args, "title"),
       lookup_string(args, "body"));
  fl_method_call_respond_success(call, nullptr, nullptr);
}

}  // namespace

void notifications_start(GtkWindow* window, FlView* view) {
  notifications.window = window;
  notifications.keys = g_hash_table_new_full(g_direct_hash, g_direct_equal,
                                             nullptr, g_free);
  notifications.closed_keys = g_hash_table_new_full(g_direct_hash, g_direct_equal,
                                                    nullptr, g_free);
  notifications.closed_timers = g_hash_table_new(g_direct_hash, g_direct_equal);
  notifications.cancellable = g_cancellable_new();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  notifications.channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "eclipse/notifications", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(notifications.channel, on_method,
                                            nullptr, nullptr);
  g_autoptr(GError) error = nullptr;
  notifications.connection =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (notifications.connection == nullptr) {
    g_warning("No session bus for notifications: %s", error->message);
    return;
  }
  notifications.action_sub_id = g_dbus_connection_signal_subscribe(
      notifications.connection, kService, kService, "ActionInvoked", kPath,
      nullptr, G_DBUS_SIGNAL_FLAGS_NONE, on_action, nullptr, nullptr);
  notifications.closed_sub_id = g_dbus_connection_signal_subscribe(
      notifications.connection, kService, kService, "NotificationClosed",
      kPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, on_closed, nullptr, nullptr);
}

void notifications_stop() {
  if (notifications.cancellable != nullptr) {
    g_cancellable_cancel(notifications.cancellable);
    g_clear_object(&notifications.cancellable);
  }
  if (notifications.connection != nullptr) {
    if (notifications.action_sub_id != 0) {
      g_dbus_connection_signal_unsubscribe(notifications.connection,
                                           notifications.action_sub_id);
      notifications.action_sub_id = 0;
    }
    if (notifications.closed_sub_id != 0) {
      g_dbus_connection_signal_unsubscribe(notifications.connection,
                                           notifications.closed_sub_id);
      notifications.closed_sub_id = 0;
    }
    g_clear_object(&notifications.connection);
  }
  if (notifications.channel != nullptr) {
    fl_method_channel_set_method_call_handler(notifications.channel, nullptr,
                                              nullptr, nullptr);
    g_clear_object(&notifications.channel);
  }
  if (notifications.closed_timers != nullptr) {
    g_hash_table_foreach(notifications.closed_timers, remove_timer, nullptr);
    g_clear_pointer(&notifications.closed_timers, g_hash_table_destroy);
  }
  g_clear_pointer(&notifications.closed_keys, g_hash_table_destroy);
  g_clear_pointer(&notifications.keys, g_hash_table_destroy);
  notifications.window = nullptr;
}
