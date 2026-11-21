import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridge to MainActivity.kt: "open with" links and picture-in-picture.
class Native {
  static const _ch = MethodChannel('reel/native');
  static final opens = StreamController<String>.broadcast();
  static final pip = ValueNotifier<bool>(false);

  static void init() {
    _ch.setMethodCallHandler((c) async {
      if (c.method == 'open' && c.arguments is String) opens.add(c.arguments as String);
      if (c.method == 'pip') pip.value = c.arguments == true;
      return null;
    });
  }

  static Future<String?> initial() async {
    try {
      return await _ch.invokeMethod<String>('initial');
    } catch (_) {
      return null;
    }
  }

  /// Tries to turn a content:// link into a real file path (so progress and
  /// next-episode work). Returns (path or null, display name or null).
  static Future<(String?, String?)> resolve(String uri) async {
    try {
      final r = await _ch.invokeMethod<Map>('resolve', uri);
      return (r?['path'] as String?, r?['name'] as String?);
    } catch (_) {
      return (null, null);
    }
  }

  static Future<void> setAutoPip(bool on, double aspect) async {
    try {
      await _ch.invokeMethod('autoPip', {'on': on, 'aspect': aspect});
    } catch (_) {}
  }

  static Future<bool> enterPip() async {
    try {
      return (await _ch.invokeMethod<bool>('pip')) ?? false;
    } catch (_) {
      return false;
    }
  }
}
