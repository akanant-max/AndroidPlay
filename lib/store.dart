import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models.dart';
import 'parser.dart';
import 'thumbs.dart';

const videoExts = {
  'mkv', 'mp4', 'm4v', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm2ts',
  'mts', 'mpg', 'mpeg', 'vob', 'ogv', '3gp', 'divx', 'asf', 'rmvb', 'f4v',
};

final store = Store();

String showKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

Future<bool> hasStorage() async {
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (await Permission.videos.isGranted) return true;
  return Permission.storage.isGranted;
}

Future<bool> ensureStorage() async {
  if (await hasStorage()) return true;
  if ((await Permission.manageExternalStorage.request()).isGranted) return true;
  final r = await [Permission.videos, Permission.storage].request();
  return r.values.any((s) => s.isGranted);
}

String _folderShow(String path) {
  final d = p.dirname(path);
  var n = p.basename(d);
  if (RegExp(r'^(season|series|s)\s*\d+$', caseSensitive: false).hasMatch(n)) {
    n = p.basename(p.dirname(d));
  }
  n = n.replaceAll(RegExp(r'[._]'), ' ').trim();
  return n.isEmpty ? 'Unknown show' : n;
}

Item buildItem(String path, int size, int mtime) {
  final base = p.basenameWithoutExtension(path);
  final pr = parseName(base);
  if (pr.season != null && pr.episode != null) {
    final show = pr.title.isNotEmpty ? pr.title : _folderShow(path);
    return Item(
      path: path, title: base, show: show, season: pr.season,
      episode: pr.episode, sub: pr.sub, size: size, added: mtime,
    );
  }
  return Item(
    path: path, title: pr.title, year: pr.year, size: size, added: mtime,
  );
}

class Store extends ChangeNotifier {
  List<String> folders = [];
  List<Item> items = [];
  Map<String, Item> byPath = {};
  final Map<String, Prog> progress = {};
  bool scanning = false;

  // settings
  String hwdec = 'auto-safe';
  bool fastScrub = false,
      autoNext = true,
      thumbsOn = true,
      scanOnStart = true,
      resume = true,
      landscape = true;
  int seekStep = 10;
  double volume = 100, subSize = 26;
  String alang = '', slang = '';

  late String dir;
  late File _file;
  Timer? _t;
  Map<String, List<Item>>? _shows;

  Future<void> load() async {
    dir = (await getApplicationSupportDirectory()).path;
    thumbs.init(dir);
    _file = File(p.join(dir, 'library.json'));
    try {
      if (_file.existsSync()) {
        final j = jsonDecode(_file.readAsStringSync()) as Map;
        folders = [for (final f in (j['folders'] as List? ?? [])) f as String];
        items = [
          for (final i in (j['items'] as List? ?? [])) Item.fromJson(i as Map)
        ];
        final pg = (j['progress'] as Map?) ?? {};
        pg.forEach((k, v) => progress[k as String] = Prog.fromJson(v as Map));
        final s = (j['settings'] as Map?) ?? {};
        hwdec = (s['hwdec'] as String?) ?? hwdec;
        fastScrub = (s['fastScrub'] as bool?) ?? fastScrub;
        autoNext = (s['autoNext'] as bool?) ?? autoNext;
        thumbsOn = (s['thumbsOn'] as bool?) ?? thumbsOn;
        scanOnStart = (s['scanOnStart'] as bool?) ?? scanOnStart;
        resume = (s['resume'] as bool?) ?? resume;
        landscape = (s['landscape'] as bool?) ?? landscape;
        seekStep = (s['seekStep'] as int?) ?? seekStep;
        volume = ((s['volume'] as num?) ?? volume).toDouble();
        subSize = ((s['subSize'] as num?) ?? subSize).toDouble();
        alang = (s['alang'] as String?) ?? alang;
        slang = (s['slang'] as String?) ?? slang;
      }
    } catch (_) {}
    _index();
  }

  void _index() {
    byPath = {for (final i in items) i.path: i};
    _shows = null;
  }

  Map<String, dynamic> _json() => {
        'folders': folders,
        'items': [for (final i in items) i.toJson()],
        'progress': {for (final e in progress.entries) e.key: e.value.toJson()},
        'settings': {
          'hwdec': hwdec, 'fastScrub': fastScrub, 'autoNext': autoNext,
          'thumbsOn': thumbsOn, 'scanOnStart': scanOnStart, 'resume': resume,
          'landscape': landscape, 'seekStep': seekStep, 'volume': volume,
          'subSize': subSize, 'alang': alang, 'slang': slang,
        },
      };

  void _dirty() {
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 600), flush);
  }

  void flush() {
    _t?.cancel();
    try {
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_json()));
      tmp.renameSync(_file.path);
    } catch (_) {}
  }

  void update(VoidCallback f) {
    f();
    _dirty();
    notifyListeners();
  }

  void touch() {
    _dirty();
    notifyListeners();
  }

  // ---- progress ----
  Prog? prog(String path) => progress[path];

  void setProg(String path, int pos, int dur) {
    final pr = progress.putIfAbsent(path, () => Prog());
    pr.pos = pos;
    pr.dur = dur;
    pr.updated = DateTime.now().millisecondsSinceEpoch;
    if (dur > 0 && pos >= dur * 0.92) pr.watched = true;
    _dirty();
  }

  void markWatched(String path, bool w) {
    final pr = progress.putIfAbsent(path, () => Prog());
    pr.watched = w;
    if (!w) pr.pos = 0;
    pr.updated = DateTime.now().millisecondsSinceEpoch;
    touch();
  }

  void resetProg(String path) {
    progress.remove(path);
    touch();
  }

  // ---- folders / scanning ----
  Future<void> addFolder(String path) async {
    if (!folders.contains(path)) {
      folders.add(path);
      _dirty();
      notifyListeners();
    }
    await rescan(ask: true);
  }

  void removeFolder(String path) {
    folders.remove(path);
    items = items.where((i) => !p.isWithin(path, i.path)).toList();
    _index();
    touch();
  }

  Future<void> rescan({bool ask = false}) async {
    if (scanning || folders.isEmpty) return;
    if (ask ? !await ensureStorage() : !await hasStorage()) return;
    scanning = true;
    notifyListeners();
    final found = <String, Item>{};
    try {
      for (final root in folders) {
        var ok = true;
        var n = 0;
        final d = Directory(root);
        if (!d.existsSync()) {
          ok = false;
        } else {
          try {
            await for (final e in d
                .list(recursive: true, followLinks: false)
                .handleError((_) => ok = false)) {
              if (e is! File) continue;
              final path = e.path;
              if (path.contains('${p.separator}.') ||
                  path.contains('${p.separator}Android${p.separator}')) {
                continue;
              }
              final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
              if (!videoExts.contains(ext)) continue;
              final st = await e.stat();
              if (p.basename(path).toLowerCase().contains('sample') &&
                  st.size < 100 * 1024 * 1024) {
                continue;
              }
              found[path] =
                  buildItem(path, st.size, st.modified.millisecondsSinceEpoch);
              if (++n % 150 == 0) await Future<void>.delayed(Duration.zero);
            }
          } catch (_) {
            ok = false;
          }
        }
        if (!ok) {
          for (final i in items) {
            if (p.isWithin(root, i.path)) found.putIfAbsent(i.path, () => i);
          }
        }
      }
      items = found.values.toList()..sort((a, b) => b.added.compareTo(a.added));
      _index();
      flush();
      for (final i in items) {
        thumbs.want(i);
      }
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  // ---- views ----
  List<Item> get movies => items.where((i) => !i.isEpisode).toList();

  Map<String, List<Item>> get shows {
    final cached = _shows;
    if (cached != null) return cached;
    final m = <String, List<Item>>{};
    for (final i in items) {
      if (i.isEpisode) m.putIfAbsent(showKey(i.show!), () => []).add(i);
    }
    for (final l in m.values) {
      l.sort((a, b) {
        final c = a.season!.compareTo(b.season!);
        if (c != 0) return c;
        final e = a.episode!.compareTo(b.episode!);
        return e != 0 ? e : a.path.compareTo(b.path);
      });
    }
    return _shows = m;
  }

  (List<Item>, int) queueFor(Item it) {
    if (!it.isEpisode) return ([it], 0);
    final l = shows[showKey(it.show!)] ?? [it];
    final i = l.indexWhere((e) => e.path == it.path);
    return (l, i < 0 ? 0 : i);
  }

  Item adhoc(String path) {
    final f = byPath[path];
    if (f != null) return f;
    var size = 0;
    try {
      size = File(path).lengthSync();
    } catch (_) {}
    return buildItem(path, size, 0);
  }

  List<Item> continueWatching() {
    final out = <MapEntry<Item, int>>[];
    progress.forEach((path, pr) {
      final it = byPath[path];
      if (it != null && !pr.watched && pr.pos > 15000 && pr.dur > 0) {
        out.add(MapEntry(it, pr.updated));
      }
    });
    out.sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in out.take(20)) e.key];
  }

  List<Item> nextUp() {
    final out = <MapEntry<Item, int>>[];
    for (final eps in shows.values) {
      var last = -1, when = 0;
      for (var i = 0; i < eps.length; i++) {
        final pr = progress[eps[i].path];
        if (pr != null && pr.watched && pr.updated >= when) {
          last = i;
          when = pr.updated;
        }
      }
      if (last >= 0 && last + 1 < eps.length) {
        final n = eps[last + 1];
        final pr = progress[n.path];
        if (pr == null || (!pr.watched && pr.pos <= 15000)) {
          out.add(MapEntry(n, when));
        }
      }
    }
    out.sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in out.take(20)) e.key];
  }

  List<Item> recent() => items.take(30).toList();

  int resumeIndex(List<Item> eps) {
    var best = -1, bu = 0;
    for (var i = 0; i < eps.length; i++) {
      final pr = progress[eps[i].path];
      if (pr != null && !pr.watched && pr.pos > 15000 && pr.updated > bu) {
        best = i;
        bu = pr.updated;
      }
    }
    if (best >= 0) return best;
    var last = -1;
    for (var i = 0; i < eps.length; i++) {
      if (progress[eps[i].path]?.watched == true) last = i;
    }
    return last + 1 < eps.length ? last + 1 : 0;
  }
}
