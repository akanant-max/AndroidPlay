import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await store.load();
  runApp(const ReelApp());
  if (store.scanOnStart && store.folders.isNotEmpty) {
    unawaited(store.rescan());
  }
}

class ReelApp extends StatelessWidget {
  const ReelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C8CFF),
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
