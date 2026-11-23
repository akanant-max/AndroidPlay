import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'native.dart';
import 'pages.dart';
import 'platform.dart';
import 'player.dart';
import 'store.dart';

final navKey = GlobalKey<NavigatorState>();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initWindow();
  Native.init();
  await store.load();
  FlutterError.onError = (d) {
    store.logError('${d.exceptionAsString()}\n${d.stack}');
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, s) {
    store.logError('$e\n$s');
    return true;
  };
  runApp(const AuraApp());
  if (store.scanOnStart) unawaited(store.rescan());
  Native.opens.stream.listen(openExternal);
  // Windows "Open with": the file path arrives as an argument.
  final argFile = args.where((a) => File(a).existsSync()).firstOrNull;
  if (argFile != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => openExternal(argFile));
  }
  final first = await Native.initial();
  if (first != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => openExternal(first));
  }
}

/// Play a video handed over by another app ("Open with").
Future<void> openExternal(String uri) async {
  final (String?, String?) r = File(uri).existsSync() ? (uri, null) : await Native.resolve(uri);
  final (path, name) = r;
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

class AuraApp extends StatelessWidget {
  const AuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AURA',
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
