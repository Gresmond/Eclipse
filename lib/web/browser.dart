/// What only a browser has; the other builds get a stand-in that's never used.
library;

export 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart';
