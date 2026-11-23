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
const subExts = {'srt', 'ass', 'ssa', 'vtt', 'sub', 'sup'};
const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 2.75, 3.0, 4.0];

final store = Store();

String showKey(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool isVideo(String path) =>
    videoExts.contains(p.extension(path).toLowerCase().replaceFirst('.', ''));

Future<bool> hasStorage() async {
  if (!Platform.isAndroid) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (await Permission.videos.isGranted) return true;
  return Permission.storage.isGranted;
}

Future<bool> ensureStorage() async {
  if (!Platform.isAndroid) return true;
  if (await hasStorage()) return true;
  if ((await Permission.manageExternalStorage.request()).isGranted) return true;
  final r = await [Permission.videos, Permission.storage].request();
  return r.values.any((s) => s.isGranted);
}

String _folderShow(String path) {
  final d = p.dirname(path);
  var n = p.basename(d);
  if (seasonFromDir(n) != null) n = p.basename(p.dirname(d));
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
  // "Show/Season 2/E05 - Title.mkv" style
  final dirSeason = seasonFromDir(p.basename(p.dirname(path)));
  if (dirSeason != null) {
    final e = episodeOnly(base);
    if (e != null) {
      return Item(
        path: path, title: base, show: _folderShow(path), season: dirSeason,
        episode: e.$1, sub: e.$2, size: size, added: mtime,
      );
    }
  }
  return Item(path: path, title: pr.title, year: pr.year, size: size, added: mtime);
}

int _natural(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).toList();
  final y = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final s = x[i].group(0)!, t = y[i].group(0)!;
    final ns = int.tryParse(s), nt = int.tryParse(t);
    final c = (ns != null && nt != null) ? ns.compareTo(nt) : s.compareTo(t);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}

int naturalCompare(String a, String b) => _natural(a, b);

class Store extends ChangeNotifier {
  List<String> folders = [], files = [];
  List<Item> items = [];
  Map<String, Item> byPath = {};
  final Map<String, Prog> progress = {};
  final List<Coll> colls = [];
  final Set<String> hidden = {};
  final Map<String, ShowMarks> marks = {};
  final Map<String, TrackPref> trackPrefs = {};
  final Map<String, int> durs = {};
  /// The user's own play queue (paths), shown in the Folders tab.
  final List<String> queue = [];
  bool scanning = false;

  // settings
  String hwdec = 'auto-safe', layout = 'grid', alang = '', slang = '';
  bool fastScrub = false,
      autoNext = true,
      thumbsOn = true,
      scanOnStart = true,
      resume = true,
      landscape = true,
      autoSkipIntro = false,
      autoPip = true,
      subBox = false,
      libassOn = true,
      wheelSeek = false;
  int crashes = 0;
  String? crashNotice;
  int seekStep = 10, nextBeforeEnd = 60, gridSize = 1, movieSort = 0, showSort = 0;
  double volume = 100, subScale = 1.0, defaultSpeed = 1.0, speedStep = 0;

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
        List<String> strs(String k) => [for (final f in (j[k] as List? ?? [])) f as String];
        folders = strs('folders');
        files = strs('files');
        hidden.addAll(strs('hidden'));
        items = [for (final i in (j['items'] as List? ?? [])) Item.fromJson(i as Map)];
        ((j['progress'] as Map?) ?? {})
            .forEach((k, v) => progress[k as String] = Prog.fromJson(v as Map));
        colls.addAll([for (final c in (j['colls'] as List? ?? [])) Coll.fromJson(c as Map)]);
        ((j['marks'] as Map?) ?? {})
            .forEach((k, v) => marks[k as String] = ShowMarks.fromJson(v as Map));
        queue.addAll(strs('queue'));
        ((j['durs'] as Map?) ?? {})
            .forEach((k, v) => durs[k as String] = (v as num).toInt());
        ((j['tracks'] as Map?) ?? {})
            .forEach((k, v) => trackPrefs[k as String] = TrackPref.fromJson(v as Map));
        final s = (j['settings'] as Map?) ?? {};
        T g<T>(String k, T d) => (s[k] is T) ? s[k] as T : d;
        double gd(String k, double d) => ((s[k] as num?) ?? d).toDouble();
        hwdec = g('hwdec', hwdec);
        layout = g('layout', layout);
        alang = g('alang', alang);
        slang = g('slang', slang);
        fastScrub = g('fastScrub', fastScrub);
        autoNext = g('autoNext', autoNext);
        thumbsOn = g('thumbsOn', thumbsOn);
        scanOnStart = g('scanOnStart', scanOnStart);
        resume = g('resume', resume);
        landscape = g('landscape', landscape);
        autoSkipIntro = g('autoSkipIntro', autoSkipIntro);
        autoPip = g('autoPip', autoPip);
        subBox = g('subBox', subBox);
        libassOn = g('libassOn', libassOn);
        wheelSeek = g('wheelSeek', wheelSeek);
        crashes = g('crashes', crashes);
        seekStep = g('seekStep', seekStep);
        nextBeforeEnd = g('nextBeforeEnd', nextBeforeEnd);
        gridSize = g('gridSize', gridSize);
        movieSort = g('movieSort', movieSort);
        showSort = g('showSort', showSort);
        volume = gd('volume', volume);
        subScale = gd('subScale', subScale);
        defaultSpeed = gd('defaultSpeed', defaultSpeed);
        speedStep = gd('speedStep', speedStep);
      }
    } catch (_) {}
    _index();
    _checkCrashMarker();
  }

  // ---------------------------------------------------------- crash guard
  File get _marker => File(p.join(dir, 'player_open.flag'));
  File get errorLog => File(p.join(dir, 'errors.log'));

  /// The marker exists only while the player is starting. If it is still
  /// there at launch, the player crashed: fall back to safer settings.
  void _checkCrashMarker() {
    try {
      if (!_marker.existsSync()) return;
      _marker.deleteSync();
      crashes++;
      if (libassOn) {
        libassOn = false;
        crashNotice = 'The player closed unexpectedly last time, so AURA switched to simple subtitles. '
            'You can turn the full subtitle renderer back on in Settings.';
      } else if (hwdec != 'mediacodec-copy' && hwdec != 'no') {
        hwdec = 'mediacodec-copy';
        crashNotice = 'The player closed unexpectedly again, so AURA switched hardware decoding to '
            '"MediaCodec copy". You can change it in Settings.';
      } else {
        crashNotice = 'The player closed unexpectedly again. Settings → Error log may show why.';
      }
      logError('Player crashed during start (crash #$crashes)');
      flush();
    } catch (_) {}
  }

  void playerStarting() {
    try {
      _marker.writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  void playerStarted() {
    try {
      if (_marker.existsSync()) _marker.deleteSync();
    } catch (_) {}
  }

  void logError(String text) {
    try {
      final f = errorLog;
      if (f.existsSync() && f.lengthSync() > 60000) f.deleteSync();
      f.writeAsStringSync('[${DateTime.now().toIso8601String()}] $text\n\n', mode: FileMode.append);
    } catch (_) {}
  }

  void _index() {
    byPath = {for (final i in items) i.path: i};
    _shows = null;
  }

  Map<String, dynamic> _json() => {
        'folders': folders,
        'files': files,
        'hidden': hidden.toList(),
        'items': [for (final i in items) i.toJson()],
        'progress': {for (final e in progress.entries) e.key: e.value.toJson()},
        'colls': [for (final c in colls) c.toJson()],
        'marks': {for (final e in marks.entries) e.key: e.value.toJson()},
        'tracks': {for (final e in trackPrefs.entries) e.key: e.value.toJson()},
        'durs': durs,
        'queue': queue,
        'settings': {
          'hwdec': hwdec, 'layout': layout, 'alang': alang, 'slang': slang,
          'fastScrub': fastScrub, 'autoNext': autoNext, 'thumbsOn': thumbsOn,
          'scanOnStart': scanOnStart, 'resume': resume, 'landscape': landscape,
          'autoSkipIntro': autoSkipIntro, 'autoPip': autoPip, 'subBox': subBox,
          'libassOn': libassOn, 'crashes': crashes, 'wheelSeek': wheelSeek,
          'seekStep': seekStep, 'nextBeforeEnd': nextBeforeEnd,
          'gridSize': gridSize, 'movieSort': movieSort, 'showSort': showSort,
          'volume': volume, 'subScale': subScale, 'defaultSpeed': defaultSpeed,
          'speedStep': speedStep,
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

  // ---------------------------------------------------------- progress
  Prog? prog(String path) => progress[path];
  int lastPlayed(String path) => progress[path]?.updated ?? 0;

  void setProg(String path, int pos, int dur) {
    final pr = progress.putIfAbsent(path, () => Prog());
    pr.pos = pos;
    pr.dur = dur;
    pr.updated = DateTime.now().millisecondsSinceEpoch;
    if (dur > 0 && pos >= dur * 0.92) pr.watched = true;
    _dirty();
  }

  void markWatched(String path, bool w) => markMany([path], w);

  void markMany(Iterable<String> paths, bool w) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final path in paths) {
      final pr = progress.putIfAbsent(path, () => Prog());
      pr.watched = w;
      if (!w) pr.pos = 0;
      pr.updated = now;
    }
    touch();
  }

  void resetProg(String path) {
    progress.remove(path);
    touch();
  }

  int? durOf(String path) => durs[path];

  List<Item> get queueItems => [for (final x in queue) if (byPath[x] != null) byPath[x]!];

  void addToQueue(Iterable<String> paths) {
    for (final x in paths) {
      if (!queue.contains(x)) queue.add(x);
    }
    touch();
  }

  void removeFromQueue(Iterable<String> paths) {
    final s = paths.toSet();
    queue.removeWhere(s.contains);
    touch();
  }

  void moveInQueue(int from, int to) {
    if (from < 0 || from >= queue.length) return;
    final x = queue.removeAt(from);
    queue.insert(to.clamp(0, queue.length), x);
    touch();
  }

  void clearQueue() {
    queue.clear();
    touch();
  }

  void setDur(String path, int ms) {
    if (ms <= 0 || durs[path] == ms) return;
    durs[path] = ms;
    _dirty();
  }

  /// Renames a video file on disk and moves all its data along. Returns an
  /// error message, or null on success.
  String? renameFile(String oldPath, String newBase) {
    if (newBase.contains(RegExp(r'[\\/:*?"<>|]'))) return 'A name can\'t contain \\ / : * ? " < > |';
    final newPath = p.join(p.dirname(oldPath), '$newBase${p.extension(oldPath)}');
    if (File(newPath).existsSync()) return 'A file with that name already exists';
    try {
      File(oldPath).renameSync(newPath);
    } catch (_) {
      return 'Could not rename the file';
    }
    // subtitles with the same name move too
    try {
      final oldBase = p.basenameWithoutExtension(oldPath);
      for (final f in Directory(p.dirname(oldPath)).listSync().whereType<File>()) {
        final b = p.basename(f.path);
        if (b.startsWith('$oldBase.') && subExts.contains(p.extension(b).toLowerCase().replaceFirst('.', ''))) {
          f.renameSync(p.join(p.dirname(oldPath), newBase + b.substring(oldBase.length)));
        }
      }
    } catch (_) {}
    final i = items.indexWhere((x) => x.path == oldPath);
    if (i >= 0) {
      final o = items[i];
      items[i] = buildItem(newPath, o.size, o.added);
    }
    void move<T>(Map<String, T> m) {
      final v = m.remove(oldPath);
      if (v != null) m[newPath] = v;
    }

    move(progress);
    move(durs);
    move(marks);
    final tp = trackPrefs.remove('file:$oldPath');
    if (tp != null) trackPrefs['file:$newPath'] = tp;
    void swap(List<String> l) {
      final j = l.indexOf(oldPath);
      if (j >= 0) l[j] = newPath;
    }

    swap(files);
    swap(queue);
    for (final c in colls) {
      swap(c.items);
    }
    if (hidden.remove(oldPath)) hidden.add(newPath);
    _index();
    touch();
    if (i >= 0) thumbs.want(items[i]);
    return null;
  }

  /// Deletes the video files from the phone. Returns how many failed.
  int deleteFiles(Iterable<String> paths) {
    var failed = 0;
    for (final x in paths.toList()) {
      try {
        final f = File(x);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        failed++;
        continue;
      }
      items.removeWhere((i) => i.path == x);
      files.remove(x);
      progress.remove(x);
      durs.remove(x);
      queue.remove(x);
      hidden.remove(x);
      for (final c in colls) {
        c.items.remove(x);
      }
    }
    _index();
    touch();
    return failed;
  }

  void hide(Iterable<String> paths) {
    hidden.addAll(paths);
    _shows = null;
    touch();
  }

  void unhideAll() {
    hidden.clear();
    _shows = null;
    touch();
  }

  // ---------------------------------------------------------- sources
  Future<void> addFolder(String path) async {
    if (!folders.contains(path)) {
      folders.add(path);
      touch();
    }
    await rescan(ask: true);
  }

  void removeFolder(String path) {
    folders.remove(path);
    items = items
        .where((i) => !p.isWithin(path, i.path) || files.contains(i.path))
        .toList();
    _index();
    touch();
  }

  Future<void> addFiles(Iterable<String> paths) async {
    for (final f in paths) {
      if (!files.contains(f)) files.add(f);
    }
    touch();
    await rescan(ask: true);
  }

  void removeFile(String path) {
    files.remove(path);
    if (!folders.any((f) => p.isWithin(f, path))) {
      items.removeWhere((i) => i.path == path);
      _index();
    }
    touch();
  }

  Future<void> rescan({bool ask = false}) async {
    if (scanning || (folders.isEmpty && files.isEmpty)) return;
    if (ask ? !await ensureStorage() : !await hasStorage()) return;
    scanning = true;
    notifyListeners();
    final found = <String, Item>{};
    try {
      for (final root in folders) {
        var ok = true, n = 0;
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
                  path.contains('${p.separator}\$') ||
                  path.contains('${p.separator}Android${p.separator}')) {
                continue;
              }
              if (!isVideo(path)) continue;
              final st = await e.stat();
              if (p.basename(path).toLowerCase().contains('sample') &&
                  st.size < 100 * 1024 * 1024) {
                continue;
              }
              final old = byPath[path];
              found[path] = (old != null &&
                      old.size == st.size &&
                      old.added == st.modified.millisecondsSinceEpoch)
                  ? old
                  : buildItem(path, st.size, st.modified.millisecondsSinceEpoch);
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
      for (final f in files) {
        if (found.containsKey(f)) continue;
        final file = File(f);
        if (file.existsSync()) {
          final st = file.statSync();
          found[f] = buildItem(f, st.size, st.modified.millisecondsSinceEpoch);
        } else if (byPath[f] != null) {
          found[f] = byPath[f]!;
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

  // ---------------------------------------------------------- views
  Iterable<Item> get visible => items.where((i) => !hidden.contains(i.path));
  List<Item> get movies => visible.where((i) => !i.isEpisode).toList();

  Map<String, List<Item>> get shows {
    final cached = _shows;
    if (cached != null) return cached;
    final m = <String, List<Item>>{};
    for (final i in visible) {
      if (i.isEpisode) m.putIfAbsent(showKey(i.show!), () => []).add(i);
    }
    for (final l in m.values) {
      l.sort(compareEpisodes);
    }
    return _shows = m;
  }

  static int compareEpisodes(Item a, Item b) {
    final c = a.season!.compareTo(b.season!);
    if (c != 0) return c;
    final e = a.episode!.compareTo(b.episode!);
    return e != 0 ? e : naturalCompare(a.path, b.path);
  }

  (List<Item>, int) queueFor(Item it) {
    if (!it.isEpisode) return ([it], 0);
    final l = shows[showKey(it.show!)] ?? [it];
    final i = l.indexWhere((e) => e.path == it.path);
    return (l, i < 0 ? 0 : i);
  }

  /// Queue for a file opened from outside: library show, else its folder.
  (List<Item>, int) queueForPath(String path) {
    final known = byPath[path];
    if (known != null) return queueFor(known);
    final me = adhoc(path);
    try {
      final sib = Directory(p.dirname(path))
          .listSync()
          .whereType<File>()
          .where((f) => isVideo(f.path))
          .map((f) => f.path == path ? me : adhoc(f.path))
          .toList();
      if (me.isEpisode) {
        final same = sib
            .where((x) => x.isEpisode && showKey(x.show!) == showKey(me.show!))
            .toList()
          ..sort(compareEpisodes);
        final i = same.indexWhere((x) => x.path == path);
        if (i >= 0) return (same, i);
      } else {
        sib.sort((a, b) => naturalCompare(a.path, b.path));
        final i = sib.indexWhere((x) => x.path == path);
        if (i >= 0) return ([sib[i]], 0);
      }
    } catch (_) {}
    return ([me], 0);
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
      if (it != null &&
          !hidden.contains(path) &&
          !pr.watched &&
          pr.pos > 15000 &&
          pr.dur > 0) {
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

  List<Item> recent() => visible.take(30).toList();

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

  /// Sort modes: 0 title, 1 recently added, 2 recently watched, 3 year, 4 size.
  static const sortNames = ['Title', 'Recently added', 'Recently watched', 'Year', 'Size'];

  // ---------------------------------------------------------- collections
  String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Coll? coll(String? id) {
    if (id == null) return null;
    for (final c in colls) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<Coll> childrenOf(String? parent) =>
      colls.where((c) => c.parent == parent).toList()
        ..sort((a, b) => naturalCompare(a.name, b.name));

  Coll createColl(String name, {String? parent}) {
    final c = Coll(id: _newId(), name: name.trim().isEmpty ? 'New folder' : name.trim(), parent: parent);
    colls.add(c);
    touch();
    return c;
  }

  void renameColl(String id, String name) {
    final c = coll(id);
    if (c != null && name.trim().isNotEmpty) {
      c.name = name.trim();
      touch();
    }
  }

  void deleteColl(String id) {
    final kill = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final c in colls) {
        if (c.parent != null && kill.contains(c.parent) && kill.add(c.id)) grew = true;
      }
    }
    colls.removeWhere((c) => kill.contains(c.id));
    touch();
  }

  bool _isDescendant(String id, String? of) {
    var cur = coll(of);
    while (cur != null) {
      if (cur.id == id) return true;
      cur = coll(cur.parent);
    }
    return false;
  }

  void moveColl(String id, String? newParent) {
    final c = coll(id);
    if (c == null || id == newParent || _isDescendant(id, newParent)) return;
    c.parent = newParent;
    touch();
  }

  void addToColl(String id, Iterable<String> paths) {
    final c = coll(id);
    if (c == null) return;
    for (final x in paths) {
      if (!c.items.contains(x)) c.items.add(x);
    }
    touch();
  }

  void removeFromColl(String id, Iterable<String> paths) {
    final c = coll(id);
    if (c == null) return;
    final s = paths.toSet();
    c.items.removeWhere(s.contains);
    touch();
  }

  int collCount(String id) {
    final c = coll(id);
    if (c == null) return 0;
    return c.items.where(byPath.containsKey).length +
        childrenOf(id).fold(0, (a, b) => a + collCount(b.id));
  }

  /// "Movies / Marvel / Phase 1" style path for pickers.
  String collPath(String id) {
    final parts = <String>[];
    var cur = coll(id);
    while (cur != null) {
      parts.insert(0, cur.name);
      cur = coll(cur.parent);
    }
    return parts.join(' / ');
  }

  // ---------------------------------------------------------- per show
  String prefKey(Item it) => it.isEpisode ? 'show:${showKey(it.show!)}' : 'file:${it.path}';

  ShowMarks marksFor(Item it) =>
      marks.putIfAbsent(it.isEpisode ? showKey(it.show!) : it.path, () => ShowMarks());

  void saveMarks() => _dirty();

  void setTrackPref(Item it, TrackPref pref) {
    trackPrefs[prefKey(it)] = pref;
    _dirty();
  }
}
