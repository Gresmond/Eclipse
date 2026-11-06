/// SQLite: the system's on a computer or phone, WebAssembly in a browser.
library;

export 'sqlite_native.dart' if (dart.library.js_interop) 'sqlite_web.dart';
