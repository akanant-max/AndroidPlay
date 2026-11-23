import 'dart:io';

import 'package:flutter/widgets.dart' show Size;
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

/// Small helpers so the same app runs on Android and Windows.

bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

const phoneRoot = '/storage/emulated/0';

String get homeDir =>
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '/';

/// Top-level places the file browser starts from.
List<String> storageRoots() {
  if (Platform.isAndroid) {
    final out = <String>[phoneRoot];
    try {
      for (final e in Directory('/storage').listSync()) {
        final n = p.basename(e.path);
        if (e is Directory && n != 'emulated' && n != 'self') out.add(e.path);
      }
    } catch (_) {}
    return out;
  }
  if (Platform.isWindows) {
    return [
      for (final c in 'CDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
        if (Directory('$c:\\').existsSync()) '$c:\\'
    ];
  }
  return ['/'];
}

String rootLabel(String r) {
  if (Platform.isAndroid) {
    return r == phoneRoot ? 'Phone storage' : 'SD card / USB (${p.basename(r)})';
  }
  return 'Drive ${r.replaceAll('\\', '')}';
}

bool isMainRoot(String r) => Platform.isAndroid ? r == phoneRoot : r.toUpperCase().startsWith('C:');

String defaultBrowseStart() {
  if (Platform.isAndroid) return phoneRoot;
  final v = p.join(homeDir, 'Videos');
  return Directory(v).existsSync() ? v : homeDir;
}

List<String> quickFolders() => Platform.isAndroid
    ? ['$phoneRoot/Movies', '$phoneRoot/Download', '$phoneRoot/DCIM', '$phoneRoot/Videos']
    : [p.join(homeDir, 'Videos'), p.join(homeDir, 'Downloads'), p.join(homeDir, 'Desktop')];

String screenshotDir() =>
    Platform.isAndroid ? '$phoneRoot/Pictures/AURA' : p.join(homeDir, 'Pictures', 'AURA');

/// Shorter, friendlier path for display.
String prettyPath(String d) {
  if (Platform.isAndroid) {
    if (d == phoneRoot) return 'Phone storage';
    if (d.startsWith('$phoneRoot/')) return 'Phone / ${d.substring(phoneRoot.length + 1)}';
    return d;
  }
  if (d.toLowerCase().startsWith(homeDir.toLowerCase())) {
    return '~${d.substring(homeDir.length)}';
  }
  return d;
}

Future<void> initWindow() async {
  if (!isDesktop) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(820, 520),
      center: true,
      title: 'AURA',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

Future<void> setFullscreen(bool v) async {
  if (!isDesktop) return;
  try {
    await windowManager.setFullScreen(v);
  } catch (_) {}
}

Future<void> setWindowTitle(String t) async {
  if (!isDesktop) return;
  try {
    await windowManager.setTitle(t);
  } catch (_) {}
}
