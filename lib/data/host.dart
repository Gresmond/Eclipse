import 'dart:io';

import 'package:flutter/foundation.dart';

/// What this computer is called on the others.
String get computerName => kIsWeb
    ? 'Browser'
    : Platform.isAndroid
    ? 'Phone'
    : Platform.localHostname;
