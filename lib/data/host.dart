import 'dart:io';

import 'package:flutter/foundation.dart';

/// Running as the Mac app. `Platform` throws in a browser, so code that the
/// web build reaches asks here.
bool get isMacApp => !kIsWeb && Platform.isMacOS;

/// What this computer is called on the others.
String get computerName => kIsWeb
    ? 'Browser'
    : Platform.isAndroid
    ? 'Phone'
    : Platform.localHostname;
