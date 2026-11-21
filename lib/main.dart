import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'native.dart';
import 'pages.dart';
import 'player.dart';
import 'store.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  Native.init();
  await store.load();
  runApp(const ReelApp());
  if (store.scanOnStart) unawaited(store.rescan());
  Native.opens.stream.listen(openExternal);
  final first = await Native.initial();
  if (first != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => openExternal(first));
  }
}

/// Play a video handed over by another app ("Open with").
Future<void> openExternal(String uri) async {
  final (path, name) = await Native.resolve(uri);
  List<Item> q;
  int i;
  if (path != null && File(path).existsSync()) {
    (q, i) = store.queueForPath(path);
  } else {
    q = [Item(path: uri, title: name ?? 'Video')];
    i = 0;
  }
  navKey.currentState?.push(MaterialPageRoute(builder: (_) => PlayerPage(queue: q, index: i)));
}

class ReelApp extends StatelessWidget {
  const ReelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reel',
      navigatorKey: navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFF5A524),
        scaffoldBackgroundColor: const Color(0xFF0E0E12),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0E0E12),
          surfaceTintColor: Colors.transparent,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF14141A),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const Shell(),
    );
  }
}
