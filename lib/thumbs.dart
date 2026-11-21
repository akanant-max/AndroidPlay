import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart';

String fnv(String s) {
  var h1 = 0x811c9dc5, h2 = 0x01000193 ^ s.length;
  for (final c in s.codeUnits) {
    h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
    h2 = (((h2 + c) * 0x5bd1e995) ^ (h2 >> 7)) & 0xFFFFFFFF;
  }
  return h1.toRadixString(16).padLeft(8, '0') + h2.toRadixString(16).padLeft(8, '0');
}

final thumbs = Thumbs();

final _artCache = <String, String?>{};

/// Poster/thumbnail picture sitting next to the video file, if any.
String? localArt(Item it) {
  return _artCache.putIfAbsent(it.path, () {
    final d = p.dirname(it.path);
    final b = p.basenameWithoutExtension(it.path);
    final names = ['$b-poster', '$b-thumb', b];
    if (!it.isEpisode &&
        store.items.where((x) => p.dirname(x.path) == d).length == 1) {
      names.addAll(['poster', 'folder', 'cover']);
    }
    for (final n in names) {
      for (final e in ['jpg', 'jpeg', 'png']) {
        final f = p.join(d, '$n.$e');
        if (File(f).existsSync()) return f;
      }
    }
    return null;
  });
}

final _showArtCache = <String, String?>{};

/// poster.jpg / folder.jpg / cover.jpg in the show folder, if any.
String? showArt(List<Item> eps) {
  final first = eps.first;
  return _showArtCache.putIfAbsent(first.path, () {
    final d1 = p.dirname(first.path);
    for (final d in [d1, p.dirname(d1)]) {
      for (final n in ['poster', 'folder', 'cover']) {
        for (final e in ['jpg', 'jpeg', 'png']) {
          final f = p.join(d, '$n.$e');
          if (File(f).existsSync()) return f;
        }
      }
    }
    return null;
  });
}

class Thumbs extends ChangeNotifier {
  final Set<String> _ready = {}, _failed = {}, _queued = {};
  final List<Item> _q = [];
  bool paused = false, _running = false;
  int done = 0;
  late String _dir;

  int get pending => _q.length;

  void init(String root) {
    _dir = p.join(root, 'thumbs');
    Directory(_dir).createSync(recursive: true);
    for (final f in Directory(_dir).listSync()) {
      _ready.add(p.basenameWithoutExtension(f.path));
    }
  }

  String _key(Item i) => fnv('${i.path}|${i.size}|${i.added}');
  String _path(Item i) => p.join(_dir, '${_key(i)}.jpg');
  bool has(Item i) => _ready.contains(_key(i));

  /// Picture to show for an item: sidecar art, else generated frame, else null.
  String? artFor(Item i) {
    final loc = localArt(i);
    if (loc != null) return loc;
    if (has(i)) return _path(i);
    want(i);
    return null;
  }

  void want(Item i) {
    final k = _key(i);
    if (_failed.contains(k) || _queued.contains(k)) return;
    if (_ready.contains(k) && store.durOf(i.path) != null) return;
    _queued.add(k);
    _q.add(i);
    _pump();
  }

  void regen(Item i) {
    final k = _key(i);
    try {
      File(_path(i)).deleteSync();
    } catch (_) {}
    _ready.remove(k);
    _failed.remove(k);
    _queued.remove(k);
    imageCache.clear();
    want(i);
    notifyListeners();
  }

  void clearAll() {
    for (final f in Directory(_dir).listSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    _ready.clear();
    _failed.clear();
    _queued.clear();
    _q.clear();
    imageCache.clear();
    notifyListeners();
  }

  void resume() => _pump();

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_q.isNotEmpty && store.thumbsOn) {
        if (paused) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        final it = _q.removeAt(0);
        final k = _key(it);
        if (!File(it.path).existsSync()) continue;
        if (_ready.contains(k)) {
          if (store.durOf(it.path) == null) await _probe(it);
          continue;
        }
        final ok = await _make(it);
        if (ok) {
          _ready.add(k);
          done++;
        } else {
          _failed.add(k);
        }
        notifyListeners();
      }
    } finally {
      _running = false;
    }
  }

  /// Reads only the length of a video (no picture), for the length badge.
  Future<void> _probe(Item it) async {
    Player? pl;
    try {
      pl = Player(configuration: PlayerConfiguration(bufferSize: 4 * 1024 * 1024));
      await pl.setVolume(0);
      await pl.open(Media(it.path), play: false);
      final d = await pl.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 8));
      store.setDur(it.path, d.inMilliseconds);
      notifyListeners();
    } catch (_) {
    } finally {
      try {
        await pl?.dispose();
      } catch (_) {}
    }
  }

  Future<bool> _make(Item it) async {
    Player? pl;
    try {
      pl = Player(configuration: PlayerConfiguration(bufferSize: 16 * 1024 * 1024));
      final vc = VideoController(pl,
          configuration:
              VideoControllerConfiguration(enableHardwareAcceleration: false));
      await pl.setVolume(0);
      await pl.open(Media(it.path), play: false);
      await pl.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 12));
      final ms = pl.state.duration.inMilliseconds;
      store.setDur(it.path, ms);
      await pl.seek(Duration(milliseconds: (ms * 0.12).round()));
      try {
        await vc.waitUntilFirstFrameRendered
            .timeout(const Duration(seconds: 6));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final raw = await pl.screenshot(format: 'image/jpeg');
      if (raw == null) return false;
      final codec = await ui.instantiateImageCodec(raw, targetWidth: 400);
      final fr = await codec.getNextFrame();
      final bd = await fr.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return false;
      final image = img.Image.fromBytes(
        width: fr.image.width,
        height: fr.image.height,
        bytes: bd.buffer,
        numChannels: 4,
      );
      await File(_path(it)).writeAsBytes(img.encodeJpg(image, quality: 78));
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await pl?.dispose();
      } catch (_) {}
    }
  }
}
