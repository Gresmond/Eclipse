/// Opens the database a browser keeps; only the web build has one.
library;

export 'browser_store_native.dart' if (dart.library.js_interop) 'browser_store_web.dart';
