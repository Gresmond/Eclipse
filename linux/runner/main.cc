#include <stdlib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // The C library reads the time zone only once, but follows TZ when it
  // changes, so the app can move to a new system time zone without
  // restarting (lib/data/system_time_zone.dart). Set here, before any other
  // threads start, so the app only ever replaces it.
  if (getenv("TZ") == nullptr) {
    g_autofree gchar* zone = realpath("/etc/localtime", nullptr);
    if (zone != nullptr) {
      g_autofree gchar* tz = g_strconcat(":", zone, nullptr);
      setenv("TZ", tz, 0);
    }
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
