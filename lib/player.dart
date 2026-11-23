import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:screen_brightness/screen_brightness.dart';

import 'models.dart';
import 'native.dart';
import 'platform.dart';
import 'seekbar.dart';
import 'sources.dart';
import 'store.dart';
import 'thumbs.dart';

enum _P { subs, audio, speed, chapters, more, sleep, marks, info, queue }

class _Seg {
  final double start, end;
  final String kind; // intro, recap, credits, preview
  const _Seg(this.start, this.end, this.kind);
}

class _Skip {
  final String key, label;
  final VoidCallback action;
  _Skip(this.key, this.label, this.action);
}

/// Classify a chapter title, e.g. "OP" -> intro, "Ending" -> credits.
String? chapterKind(String t) {
  final s = t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final w = s.split(' ').toSet();
  if (s.contains('preview') || s.contains('next time') || s.contains('next episode')) return 'preview';
  if (s.contains('recap') || s.contains('previously')) return 'recap';
  if (s.contains('opening') || w.contains('op') || s.contains('intro') ||
      s.contains('theme song') || s.contains('title sequence')) {
    return 'intro';
  }
  if (w.contains('ed') || s.contains('ending') || s.contains('credits') ||
      s.contains('outro') || s.contains('closing')) {
    return 'credits';
  }
  return null;
}

String _clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

class PlayerPage extends StatefulWidget {
  final List<Item> queue;
  final int index;
  final bool fromStart;
  const PlayerPage({super.key, required this.queue, required this.index, this.fromStart = false});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final Player player = Player(
    configuration: PlayerConfiguration(
      bufferSize: 64 * 1024 * 1024,
      libass: store.libassOn,
      libassAndroidFont: store.libassOn ? 'assets/subfont.ttf' : null,
      libassAndroidFontName: store.libassOn ? 'DejaVu Sans' : null,
    ),
  );
  late final VideoController video = VideoController(
    player,
    configuration: VideoControllerConfiguration(hwdec: store.hwdec),
  );

  final subs = <StreamSubscription>[];
  late int idx;
  late final List<Item> queue = List.of(widget.queue);
  final posN = ValueNotifier<Duration>(Duration.zero);
  final osdN = ValueNotifier<String?>(null);
  final ui = ValueNotifier<bool>(true);
  final skipN = ValueNotifier<_Skip?>(null);
  final clockN = ValueNotifier<String>(_clock(DateTime.now()));
  final focus = FocusNode();
  double? _lastRate;
  ScrollController? _queueCtl;
  // seek-bar preview frames (a second, silent player)
  Player? _pv;
  String? _pvPath;
  final pvN = ValueNotifier<Uint8List?>(null);
  Timer? _pvT;
  Duration? _pvWant;
  bool _pvBusy = false;
  bool fs = false;
  double _preMute = 100;
  Timer? clockT;

  Duration dur = Duration.zero;
  bool playing = false,
      buffering = true,
      locked = false,
      scrubbing = false,
      landscapeLock = true,
      loop = false,
      _ready = false,
      _prefApplied = false,
      _boosting = false,
      _hActive = false;
  double rate = store.defaultSpeed,
      _preBoost = 1.0,
      _vol = store.volume,
      _br = 0.5,
      subDelay = 0,
      audioDelay = 0,
      subPos = 100;
  BoxFit fit = BoxFit.contain;
  double? aspect;
  List<Chap> chapters = [];
  List<_Seg> segs = [];
  final Set<double> _autoSkipped = {};
  int sleepMin = 0, _gen = 0;
  _P? panel;
  List<String> infoLines = [];

  Timer? hideT, saveT, osdT, sleepT, _tgtT, _pendingTap;
  DateTime _lastSeek = DateTime(2000), _lastTap = DateTime(2000);
  Offset _lastTapPos = Offset.zero;
  int _streakSide = 0;
  Duration? _tgt;
  Duration _dragPos = Duration.zero;
  int _acc = 0, _vMode = 0;
  double _w = 1, _h = 1;
  EdgeInsets _pad = EdgeInsets.zero;

  void _ss(VoidCallback f) {
    if (mounted) setState(f);
  }

  Item get _item => queue[idx];
  bool get _hasNext => idx + 1 < queue.length;

  // ------------------------------------------------------------ lifecycle

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    idx = widget.index;
    store.playerStarting();
    landscapeLock = store.landscape;
    thumbs.paused = true;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _applyOrientation();
    _initBrightness();

    subs.addAll([
      player.stream.position.listen((v) {
        if (!scrubbing) posN.value = v;
        _checkSkip(v);
      }),
      player.stream.duration.listen((v) {
        if (v != dur) _ss(() => dur = v);
      }),
      player.stream.playing.listen((v) {
        _ss(() => playing = v);
        Native.setAutoPip(v && store.autoPip, _aspectValue());
        if (v) {
          _poke();
        } else {
          hideT?.cancel();
          ui.value = true;
        }
      }),
      player.stream.buffering.listen((v) => _ss(() => buffering = v)),
      player.stream.rate.listen((v) => _ss(() => rate = v)),
      player.stream.completed.listen((v) {
        if (v) _onCompleted();
      }),
      player.stream.tracks.listen((t) {
        if (!_prefApplied && t.audio.length > 2) _applyPref();
        _ss(() {});
      }),
      player.stream.track.listen((_) => _ss(() {})),
      player.stream.error.listen((e) {
        store.logError('mpv: $e');
        _flash('Error: $e', ms: 4000);
      }),
    ]);

    saveT = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    clockT = Timer.periodic(const Duration(seconds: 15), (_) => clockN.value = _clock(DateTime.now()));
    _start();
  }

  Future<void> _start() async {
    await _tune();
    await _open(idx, fromStart: widget.fromStart);
    _poke();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.inactive) {
      _save();
      store.flush();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.playerStarted();
    if (fs) setFullscreen(false);
    setWindowTitle('AURA');
    focus.dispose();
    _save();
    store.volume = _vol;
    store.flush();
    Future.microtask(store.touch);
    for (final s in subs) {
      s.cancel();
    }
    for (final t in [hideT, saveT, osdT, sleepT, _tgtT, _pendingTap, clockT, _wheelT, _pvT]) {
      t?.cancel();
    }
    Native.setAutoPip(false, 16 / 9);
    player.dispose();
    _pv?.dispose();
    _queueCtl?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    try {
      ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (_) {}
    thumbs.paused = false;
    thumbs.resume();
    super.dispose();
  }

  void _applyOrientation() {
    SystemChrome.setPreferredOrientations(landscapeLock
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : DeviceOrientation.values);
  }

  Future<void> _initBrightness() async {
    try {
      _br = await ScreenBrightness.instance.application;
    } catch (_) {}
  }

  double _aspectValue() {
    final w = player.state.width, h = player.state.height;
    if (w != null && h != null && w > 0 && h > 0) return w / h;
    return 16 / 9;
  }

  // ------------------------------------------------------------ mpv helpers

  Future<void> _prop(String k, String v) async {
    final n = player.platform;
    if (n is NativePlayer) {
      try {
        await n.setProperty(k, v);
      } catch (_) {}
    }
  }

  Future<String> _get(String k) async {
    final n = player.platform;
    if (n is NativePlayer) {
      try {
        return await n.getProperty(k);
      } catch (_) {}
    }
    return '';
  }

  Future<void> _hr(String v) => _prop('hr-seek', v);

  Future<void> _tune() async {
    await _hr(store.fastScrub ? 'no' : 'default');
    await _prop('cache', 'yes');
    await _prop('demuxer-max-bytes', '200MiB');
    await _prop('demuxer-max-back-bytes', '100MiB');
    await _prop('demuxer-readahead-secs', '30');
    await _prop('video-sync', 'audio');
    await _prop('audio-pitch-correction', 'yes');
    await _prop('sub-auto', 'fuzzy');
    await _prop('volume-max', '130');
    await _prop('sub-font-size', '46');
    await _prop('sub-margin-y', '30');
    if (store.alang.isNotEmpty) await _prop('alang', store.alang);
    if (store.slang.isNotEmpty) await _prop('slang', store.slang);
    await _applySubStyle();
    await player.setVolume(_vol);
  }

  Future<void> _applySubStyle() async {
    await _prop('sub-scale', store.subScale.toStringAsFixed(2));
    await _prop('sub-pos', subPos.round().toString());
    if (store.subBox) {
      await _prop('sub-border-style', 'opaque-box');
      await _prop('sub-outline-color', '#A0000000');
      await _prop('sub-back-color', '#A0000000');
      await _prop('sub-shadow-offset', '0');
    } else {
      await _prop('sub-border-style', 'outline-and-shadow');
      await _prop('sub-outline-color', '#FF000000');
      await _prop('sub-outline-size', '2.6');
      await _prop('sub-border-size', '2.6');
      await _prop('sub-shadow-offset', '1');
    }
  }

  Future<void> _loadChapters() async {
    try {
      final c = int.tryParse(await _get('chapter-list/count')) ?? 0;
      final out = <Chap>[];
      for (var i = 0; i < c; i++) {
        var t = await _get('chapter-list/$i/title');
        if (t.isEmpty) t = 'Chapter ${i + 1}';
        final tm = double.tryParse(await _get('chapter-list/$i/time')) ?? 0;
        out.add(Chap(t, tm));
      }
      out.sort((a, b) => a.time.compareTo(b.time));
      _ss(() => chapters = out);
    } catch (_) {}
    _buildSegs();
  }

  void _buildSegs() {
    final total = dur.inMilliseconds / 1000;
    final out = <_Seg>[];
    for (var i = 0; i < chapters.length; i++) {
      final k = chapterKind(chapters[i].title);
      if (k == null) continue;
      final end = i + 1 < chapters.length ? chapters[i + 1].time : total;
      if (end - chapters[i].time < 3) continue;
      // an "ending" in the first half is more likely a mislabel; skip it
      if ((k == 'credits' || k == 'preview') && total > 0 && chapters[i].time < total * 0.5) continue;
      out.add(_Seg(chapters[i].time, end, k));
    }
    final m = store.marks[_item.isEpisode ? showKey(_item.show!) : _item.path];
    if (m != null && m.introStart != null && m.introEnd != null && m.introEnd! > m.introStart!) {
      if (!out.any((s) => s.kind == 'intro')) out.add(_Seg(m.introStart!, m.introEnd!, 'intro'));
    }
    segs = out;
  }

  /// When the "Next episode" button should appear, in seconds.
  double? _creditsStart() {
    final total = dur.inMilliseconds / 1000;
    if (total <= 0) return null;
    for (final s in segs) {
      if (s.kind == 'credits' || s.kind == 'preview') return s.start;
    }
    final m = store.marks[_item.isEpisode ? showKey(_item.show!) : _item.path];
    if (m?.creditsFromEnd != null) return total - m!.creditsFromEnd!;
    if (store.nextBeforeEnd > 0 && total > store.nextBeforeEnd * 4) return total - store.nextBeforeEnd;
    return null;
  }

  void _checkSkip(Duration v) {
    if (!_ready) return;
    final s = v.inMilliseconds / 1000;
    _Skip? next;
    for (final g in segs) {
      if (s >= g.start && s < g.end - 1) {
        if (g.kind == 'intro' || g.kind == 'recap') {
          if (store.autoSkipIntro && !_autoSkipped.contains(g.start)) {
            _autoSkipped.add(g.start);
            _seekTo(Duration(milliseconds: (g.end * 1000).round()));
            _flash(g.kind == 'intro' ? 'Skipped intro' : 'Skipped recap');
            return;
          }
          next = _Skip('${g.kind}${g.start}', g.kind == 'intro' ? 'Skip Intro' : 'Skip Recap',
              () => _seekTo(Duration(milliseconds: (g.end * 1000).round())));
        } else if (_hasNext) {
          next = _Skip('next', 'Next Episode', _nextEpisode);
        } else if (g.end < dur.inMilliseconds / 1000 - 2) {
          next = _Skip('cred${g.start}', 'Skip Credits',
              () => _seekTo(Duration(milliseconds: (g.end * 1000).round())));
        }
        break;
      }
    }
    if (next == null && _hasNext) {
      final cs = _creditsStart();
      if (cs != null && s >= cs) next = _Skip('next', 'Next Episode', _nextEpisode);
    }
    if (skipN.value?.key != next?.key) skipN.value = next;
  }

  void _nextEpisode() {
    if (!_hasNext) return;
    if (dur > Duration.zero) store.setProg(_item.path, dur.inMilliseconds, dur.inMilliseconds);
    _open(idx + 1);
  }

  // ------------------------------------------------------------ playback

  Future<void> _open(int i, {bool fromStart = false}) async {
    final gen = ++_gen;
    idx = i;
    final it = _item;
    setWindowTitle('${it.isEpisode ? '${it.name} ${it.epLabel}' : it.name} — AURA');
    _ready = false;
    _prefApplied = false;
    _autoSkipped.clear();
    segs = [];
    chapters = [];
    skipN.value = null;
    dur = Duration.zero;
    posN.value = Duration.zero;
    subDelay = 0;
    audioDelay = 0;
    _ss(() {});
    final pr = store.prog(it.path);
    Duration? start;
    if (!fromStart &&
        store.resume &&
        pr != null &&
        !pr.watched &&
        pr.pos > 10000 &&
        pr.dur > 0 &&
        pr.pos < pr.dur * 0.95) {
      start = Duration(milliseconds: pr.pos - 2000);
    }
    await _prop('sub-delay', '0');
    await _prop('audio-delay', '0');
    final durF = player.stream.duration
        .firstWhere((d) => d > Duration.zero)
        .timeout(const Duration(seconds: 8));
    await player.open(Media(it.path, start: start), play: true);
    try {
      await durF;
    } catch (_) {}
    if (gen != _gen || !mounted) return;
    dur = player.state.duration;
    store.setDur(it.path, dur.inMilliseconds);
    await player.setRate(rate);
    if (start != null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (player.state.position < start - const Duration(seconds: 3)) {
        await player.seek(start);
      }
      posN.value = start;
      _flash('Resumed at ${fmt(start)}');
    }
    if (gen != _gen || !mounted) return;
    _ready = true;
    _ss(() {});
    Future<void>.delayed(const Duration(seconds: 3), store.playerStarted);
    await _loadChapters();
  }

  void _save() {
    if (!_ready || dur <= Duration.zero) return;
    final pos = posN.value.inMilliseconds;
    if (pos <= 0) return;
    store.setProg(_item.path, pos, dur.inMilliseconds);
  }

  void _onCompleted() {
    if (dur > Duration.zero) {
      store.setProg(_item.path, dur.inMilliseconds, dur.inMilliseconds);
    }
    _ready = false;
    if (store.autoNext && _hasNext) {
      _open(idx + 1);
    } else if (mounted) {
      Navigator.maybePop(context);
    }
  }

  Duration _clampD(Duration d) {
    if (d < Duration.zero) return Duration.zero;
    if (dur > Duration.zero && d > dur) return dur;
    return d;
  }

  void _seekTo(Duration t) {
    t = _clampD(t);
    posN.value = t;
    player.seek(t);
  }

  void _seekBy(int secs) {
    if (_tgt == null) _acc = 0;
    _acc += secs;
    final t = _clampD((_tgt ?? posN.value) + Duration(seconds: secs));
    _tgt = t;
    _tgtT?.cancel();
    _tgtT = Timer(const Duration(milliseconds: 800), () => _tgt = null);
    _seekTo(t);
    _flash('${_acc > 0 ? '+' : '−'}${_acc.abs()} s   ${fmt(t)}');
  }

  void _scrubStart() {
    scrubbing = true;
    if (!store.fastScrub) _hr('no');
    hideT?.cancel();
  }

  void _scrubUpdate(Duration t) {
    posN.value = t;
    final now = DateTime.now();
    if (now.difference(_lastSeek).inMilliseconds > 50) {
      _lastSeek = now;
      player.seek(t);
    }
  }

  Future<void> _scrubEnd(Duration t) async {
    if (!store.fastScrub) await _hr('default');
    scrubbing = false;
    _seekTo(t);
    _poke();
  }

  // ------------------------------------------------------------ overlay

  void _flash(String s, {int ms = 1100}) {
    osdN.value = s;
    osdT?.cancel();
    osdT = Timer(Duration(milliseconds: ms), () => osdN.value = null);
  }

  void _poke() {
    ui.value = true;
    hideT?.cancel();
    if (playing && panel == null) {
      hideT = Timer(const Duration(seconds: 3), () {
        if (playing && panel == null && !scrubbing) ui.value = false;
      });
    }
  }

  void _toggleUi() {
    if (ui.value) {
      hideT?.cancel();
      ui.value = false;
    } else {
      _poke();
    }
  }

  void _openPanel(_P p) {
    if (p == _P.queue) {
      _queueCtl?.dispose();
      _queueCtl = ScrollController(initialScrollOffset: ((idx - 2) * 52.0).clamp(0.0, double.infinity));
    }
    _ss(() => panel = panel == p ? null : p);
    hideT?.cancel();
    ui.value = true;
    if (panel == null) _poke();
  }

  void _closePanel() {
    _ss(() => panel = null);
    _poke();
  }

  // ------------------------------------------------------------ gestures

  bool _inControls(Offset o) {
    if (panel != null && o.dx > _w - 372) return true;
    if (!ui.value) return false;
    final k = isDesktop ? 1.3 : 1.0;
    return o.dy < 76 * k + _pad.top || o.dy > _h - 140 * k - _pad.bottom;
  }

  void _onTapUp(TapUpDetails d) {
    final pos = d.localPosition;
    if (panel != null) {
      _closePanel();
      return;
    }
    if (locked) {
      _toggleUi();
      return;
    }
    final now = DateTime.now();
    final side = pos.dx < _w / 3 ? -1 : (pos.dx > _w * 2 / 3 ? 1 : 0);
    if (_streakSide != 0 && side == _streakSide && now.difference(_lastTap).inMilliseconds < 700) {
      _lastTap = now;
      _seekBy(side * store.seekStep);
      return;
    }
    if (_pendingTap != null &&
        now.difference(_lastTap).inMilliseconds < 300 &&
        (pos - _lastTapPos).distance < 140) {
      _pendingTap!.cancel();
      _pendingTap = null;
      _lastTap = now;
      if (side == 0) {
        _streakSide = 0;
        // PC: double-click = fullscreen; phone: double-tap = play/pause
        if (isDesktop) {
          _toggleFs();
        } else {
          player.playOrPause();
        }
      } else {
        _streakSide = side;
        _seekBy(side * store.seekStep);
      }
      return;
    }
    _streakSide = 0;
    _lastTap = now;
    _lastTapPos = pos;
    _pendingTap = Timer(const Duration(milliseconds: 260), () {
      _pendingTap = null;
      _toggleUi();
    });
  }

  void _hStart(DragStartDetails d) {
    _hActive = !locked && dur > Duration.zero && !_inControls(d.localPosition);
    if (!_hActive) return;
    _dragPos = posN.value;
    _scrubStart();
  }

  void _hUpdate(DragUpdateDetails d) {
    if (!_hActive) return;
    _dragPos = _clampD(_dragPos + Duration(milliseconds: (d.delta.dx * 160).round()));
    _scrubUpdate(_dragPos);
    _flash('${fmt(_dragPos)} / ${fmt(dur)}', ms: 800);
  }

  void _hEnd(DragEndDetails d) {
    if (_hActive) _scrubEnd(_dragPos);
    _hActive = false;
  }

  void _vStart(DragStartDetails d) {
    _vMode = (isDesktop || locked || _inControls(d.localPosition)) ? 0 : (d.localPosition.dx < _w / 2 ? 1 : 2);
  }

  void _vUpdate(DragUpdateDetails d) {
    if (_vMode == 0) return;
    final f = -d.delta.dy / (_h * 0.7);
    if (_vMode == 1) {
      _br = (_br + f).clamp(0.0, 1.0).toDouble();
      try {
        ScreenBrightness.instance.setApplicationScreenBrightness(_br);
      } catch (_) {}
      _flash('Brightness ${(_br * 100).round()}%', ms: 800);
    } else {
      _vol = (_vol + f * 130).clamp(0.0, 130.0).toDouble();
      player.setVolume(_vol);
      _flash('Volume ${_vol.round()}%', ms: 800);
    }
  }

  void _lpStart(LongPressStartDetails d) {
    if (locked || _inControls(d.localPosition)) return;
    _boosting = true;
    _preBoost = rate;
    player.setRate(2.0);
    _flash('2× speed', ms: 60000);
  }

  void _lpEnd(LongPressEndDetails d) {
    if (!_boosting) return;
    _boosting = false;
    player.setRate(_preBoost);
    osdN.value = null;
  }

  // ------------------------------------------------------------ desktop

  Widget _desktopWrap(Widget child) {
    if (!isDesktop) return child;
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons & kMiddleMouseButton != 0) _nextChapter();
        },
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            final up = e.scrollDelta.dy < 0;
            if (store.wheelSeek) {
              _wheelSeek(up ? 5 : -5);
            } else {
              _setVolume(_vol + (up ? 5 : -5));
            }
          }
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: ui,
          builder: (context, on, c) => MouseRegion(
            cursor: (!on && playing && panel == null) ? SystemMouseCursors.none : MouseCursor.defer,
            onHover: (_) => _poke(),
            child: c,
          ),
          child: child,
        ),
      ),
    );
  }

  /// Mouse-wheel scrubbing: fast keyframe seeks while the wheel moves,
  /// then one exact seek when it stops.
  Timer? _wheelT;
  void _wheelSeek(int secs) {
    if (dur == Duration.zero) return;
    if (!scrubbing) _scrubStart();
    _tgtT?.cancel();
    final t = _clampD((_tgt ?? posN.value) + Duration(seconds: secs));
    _tgt = t;
    _scrubUpdate(t);
    _flash('${fmt(t)} / ${fmt(dur)}', ms: 900);
    _wheelT?.cancel();
    _wheelT = Timer(const Duration(milliseconds: 350), () {
      _tgt = null;
      _scrubEnd(t);
    });
  }

  void _previewAt(Duration? t) {
    if (t == null) {
      _pvT?.cancel();
      return;
    }
    _pvWant = t;
    _pvT?.cancel();
    _pvT = Timer(const Duration(milliseconds: 80), _pvRun);
  }

  Future<void> _pvRun() async {
    if (!mounted) return;
    if (_pvBusy) {
      _pvT = Timer(const Duration(milliseconds: 60), _pvRun);
      return;
    }
    final t = _pvWant;
    if (t == null) return;
    _pvBusy = true;
    try {
      if (_pv == null || _pvPath != _item.path) {
        final old = _pv;
        _pv = null;
        await old?.dispose();
        final pv = Player(configuration: PlayerConfiguration(bufferSize: 8 * 1024 * 1024));
        VideoController(pv,
            configuration: VideoControllerConfiguration(enableHardwareAcceleration: false, hwdec: 'no'));
        await pv.setVolume(0);
        final n = pv.platform;
        if (n is NativePlayer) {
          for (final kv in {'hr-seek': 'no', 'aid': 'no', 'sid': 'no', 'vf': 'scale=480:-2'}.entries) {
            try {
              await n.setProperty(kv.key, kv.value);
            } catch (_) {}
          }
        }
        await pv.open(Media(_item.path), play: false);
        try {
          await pv.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 6));
        } catch (_) {}
        _pv = pv;
        _pvPath = _item.path;
      }
      final pv = _pv!;
      await pv.seek(t);
      try {
        await pv.stream.position
            .firstWhere((p) => (p - t).inSeconds.abs() < 15)
            .timeout(const Duration(milliseconds: 700));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final b = await pv.screenshot(format: 'image/jpeg');
      if (b != null && mounted) pvN.value = b;
    } catch (_) {
    } finally {
      _pvBusy = false;
    }
  }

  void _nextChapter() {
    final s = posN.value.inMilliseconds / 1000;
    for (final c in chapters) {
      if (c.time > s + 1) {
        _seekTo(Duration(milliseconds: (c.time * 1000).round()));
        _flash(c.title);
        _poke();
        return;
      }
    }
    _flash(chapters.isEmpty ? 'No chapters' : 'Last chapter');
  }

  void _toggleFs() {
    fs = !fs;
    setFullscreen(fs);
    _ss(() {});
    focus.requestFocus();
  }

  void _setVolume(double v) {
    _vol = v.clamp(0.0, 130.0).toDouble();
    player.setVolume(_vol);
    _flash('Volume ${_vol.round()}%', ms: 800);
  }

  void _cycleSub() {
    final list = player.state.tracks.subtitle.where((t) => t.id != 'auto').toList();
    if (list.isEmpty) return;
    final i = list.indexWhere((t) => t.id == player.state.track.subtitle.id);
    final t = list[(i + 1) % list.length];
    _pickSub(t);
    _flash('Subtitles: ${_label(t, 'Subtitle')}');
  }

  void _cycleAudio() {
    final list = player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (list.length < 2) return;
    final i = list.indexWhere((t) => t.id == player.state.track.audio.id);
    final t = list[(i + 1) % list.length];
    _pickAudio(t);
    _flash('Audio: ${_label(t, 'Audio')}');
  }

  /// Presets by default; [fine] (Shift, or the panel stepper) moves 0.05×.
  void _stepSpeed(int dir, {bool fine = false}) {
    final step = fine ? 0.05 : store.speedStep;
    double v;
    if (step <= 0) {
      var i = speeds.indexWhere((s) => s >= rate - 0.001);
      if (i < 0) i = speeds.length - 1;
      if (dir > 0 && speeds[i] <= rate + 0.001) i++;
      if (dir < 0) i--;
      v = speeds[i.clamp(0, speeds.length - 1)];
    } else {
      v = ((rate / step).round() + dir) * step;
      v = (v.clamp(0.1, 4.0) * 100).round() / 100;
    }
    player.setRate(v);
    _flash('$v×');
  }

  void _frame(bool back) {
    final n = player.platform;
    if (n is NativePlayer) n.command([back ? 'frame-back-step' : 'frame-step']);
  }

  static final _digits = [
    LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  KeyEventResult _key(FocusNode n, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final rep = e is KeyRepeatEvent;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      if (!rep) player.playOrPause();
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      final step = shift ? 60 : (ctrl ? 3 : store.seekStep);
      _seekBy(k == LogicalKeyboardKey.arrowRight ? step : -step);
    } else if (k == LogicalKeyboardKey.keyJ) {
      _seekBy(-10);
    } else if (k == LogicalKeyboardKey.keyL) {
      _seekBy(10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume(_vol + 5);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume(_vol - 5);
    } else if (k == LogicalKeyboardKey.keyM) {
      if (rep) return KeyEventResult.handled;
      if (_vol > 0) {
        _preMute = _vol;
        _setVolume(0);
        _flash('Muted');
      } else {
        _setVolume(_preMute);
      }
    } else if (k == LogicalKeyboardKey.keyF || k == LogicalKeyboardKey.enter) {
      if (!rep) _toggleFs();
    } else if (k == LogicalKeyboardKey.escape) {
      if (panel != null) {
        _closePanel();
      } else if (fs) {
        _toggleFs();
      } else {
        Navigator.maybePop(context);
      }
    } else if (k == LogicalKeyboardKey.bracketLeft ||
        k == LogicalKeyboardKey.numpadSubtract ||
        k == LogicalKeyboardKey.minus) {
      _stepSpeed(-1, fine: shift);
    } else if (k == LogicalKeyboardKey.bracketRight ||
        k == LogicalKeyboardKey.numpadAdd ||
        k == LogicalKeyboardKey.equal ||
        k == LogicalKeyboardKey.add) {
      _stepSpeed(1, fine: shift);
    } else if (k == LogicalKeyboardKey.keyG) {
      if (rep) return KeyEventResult.handled;
      if ((rate - 1.0).abs() > 0.001) {
        _lastRate = rate;
        player.setRate(1.0);
        _flash('1.0×  (G again for ${rate}×)');
      } else if (_lastRate != null) {
        player.setRate(_lastRate!);
        _flash('${_lastRate}×');
      }
    } else if (k == LogicalKeyboardKey.numpadMultiply) {
      player.setRate(1.0);
      _flash('1.0×');
    } else if (k == LogicalKeyboardKey.backslash) {
      player.setRate(1.0);
      _flash('1.0×');
    } else if (k == LogicalKeyboardKey.keyS && ctrl) {
      if (!rep) _shot();
    } else if (k == LogicalKeyboardKey.keyS) {
      if (!rep) _cycleSub();
    } else if (k == LogicalKeyboardKey.keyA) {
      if (!rep) _cycleAudio();
    } else if (k == LogicalKeyboardKey.keyN) {
      if (!rep && _hasNext) {
        _save();
        _open(idx + 1);
      }
    } else if (k == LogicalKeyboardKey.keyP) {
      if (!rep && idx > 0) {
        _save();
        _open(idx - 1);
      }
    } else if (k == LogicalKeyboardKey.period) {
      _frame(false);
    } else if (k == LogicalKeyboardKey.comma) {
      _frame(true);
    } else if (k == LogicalKeyboardKey.keyC) {
      if (!rep && chapters.isNotEmpty) _openPanel(_P.chapters);
    } else if (k == LogicalKeyboardKey.keyI) {
      if (!rep) {
        _loadInfo();
        _openPanel(_P.info);
      }
    } else if (_digits.contains(k)) {
      if (dur > Duration.zero) {
        final d = _digits.indexOf(k);
        _seekTo(Duration(milliseconds: dur.inMilliseconds * d ~/ 10));
      }
    } else {
      return KeyEventResult.ignored;
    }
    _poke();
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------ tracks

  String _label(dynamic t, String kind) {
    final id = t.id as String;
    if (id == 'no') return 'Off';
    if (id == 'auto') return 'Auto';
    final title = (t.title as String?) ?? '';
    final lang = (t.language as String?) ?? '';
    final parts = [if (title.isNotEmpty) title, if (lang.isNotEmpty) lang.toUpperCase()];
    return parts.isEmpty ? '$kind $id' : parts.join(' · ');
  }

  T? _match<T>(List<T> list, String? lang, String? title) {
    T? byLang;
    for (final x in list) {
      final d = x as dynamic;
      if (d.id == 'auto' || d.id == 'no') continue;
      if (lang != null && d.language == lang) {
        if (title == null || d.title == title) return x;
        byLang ??= x;
      } else if (lang == null && title != null && d.title == title) {
        return x;
      }
    }
    return byLang;
  }

  void _applyPref() {
    _prefApplied = true;
    final pref = store.trackPrefs[store.prefKey(_item)];
    if (pref == null) return;
    final t = player.state.tracks;
    if (pref.aLang != null || pref.aTitle != null) {
      final a = _match(t.audio, pref.aLang, pref.aTitle);
      if (a != null) player.setAudioTrack(a);
    }
    if (pref.sOff) {
      player.setSubtitleTrack(SubtitleTrack.no());
    } else if (pref.sLang != null || pref.sTitle != null) {
      final s = _match(t.subtitle, pref.sLang, pref.sTitle);
      if (s != null) player.setSubtitleTrack(s);
    }
  }

  TrackPref _curPref() => store.trackPrefs[store.prefKey(_item)] ?? TrackPref();

  void _pickAudio(AudioTrack t) {
    player.setAudioTrack(t);
    final pref = _curPref()
      ..aLang = t.language
      ..aTitle = t.title;
    store.setTrackPref(_item, pref);
  }

  void _pickSub(SubtitleTrack t) {
    player.setSubtitleTrack(t);
    final pref = _curPref()
      ..sOff = t.id == 'no'
      ..sLang = t.id == 'no' ? null : t.language
      ..sTitle = t.id == 'no' ? null : t.title;
    store.setTrackPref(_item, pref);
  }

  Future<void> _loadSubFile() async {
    final path = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => BrowserPage(
        mode: BrowseMode.subtitle,
        start: File(_item.path).existsSync() ? p.dirname(_item.path) : null,
      ),
    ));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (path != null) {
      await player.setSubtitleTrack(SubtitleTrack.uri(path, title: p.basename(path)));
      _flash('Subtitle loaded');
    }
  }

  // ------------------------------------------------------------ misc actions

  Future<void> _shot() async {
    try {
      final b = await player.screenshot(format: 'image/png', includeLibassSubtitles: true);
      if (b == null) return;
      final d = Directory(screenshotDir())..createSync(recursive: true);
      final safe = _item.name.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '');
      final f = File(p.join(d.path, '${safe}_${DateTime.now().millisecondsSinceEpoch}.png'));
      await f.writeAsBytes(b);
      _flash('Saved to Pictures${Platform.pathSeparator}AURA');
    } catch (_) {
      _flash('Could not save screenshot');
    }
  }

  Future<void> _loadInfo() async {
    final w = await _get('width'), h = await _get('height');
    infoLines = [
      'Video: ${await _get('video-format')}  ${w}x$h  ${await _get('container-fps')} fps',
      'Decoder: ${await _get('hwdec-current')}  (setting: ${store.hwdec})',
      'Audio: ${await _get('audio-codec-name')}  ${await _get('audio-params/channel-count')} ch',
      'Container: ${await _get('file-format')}',
      'Dropped frames: ${await _get('frame-drop-count')}  (decoder ${await _get('decoder-frame-drop-count')})',
      'File: ${p.basename(_item.path)}',
    ];
    _ss(() {});
  }

  void _setSleep(int m) {
    sleepMin = m;
    sleepT?.cancel();
    if (m > 0) {
      sleepT = Timer(Duration(minutes: m), () {
        _save();
        if (mounted) Navigator.maybePop(context);
      });
    }
    _flash(m == 0 ? 'Sleep timer off' : 'Stopping in $m min');
    _ss(() {});
  }

  // ------------------------------------------------------------ panels

  Widget _row(String text, {bool on = false, VoidCallback? onTap, Widget? trailing, IconData? icon}) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: icon == null ? null : Icon(icon, size: 20, color: Colors.white70),
      title: Text(text, style: TextStyle(color: on ? Theme.of(context).colorScheme.primary : Colors.white)),
      trailing: trailing ?? (on ? Icon(Icons.check, size: 18, color: Theme.of(context).colorScheme.primary) : null),
      onTap: onTap,
    );
  }

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(label),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.remove_circle_outline, size: 20), onPressed: dec),
        SizedBox(width: 58, child: Text(value, textAlign: TextAlign.center)),
        IconButton(icon: const Icon(Icons.add_circle_outline, size: 20), onPressed: inc),
      ]),
    );
  }

  Widget _chips<T>(Map<T, String> opts, T cur, void Function(T) set) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Wrap(spacing: 6, runSpacing: 4, children: [
          for (final e in opts.entries)
            ChoiceChip(
              visualDensity: VisualDensity.compact,
              label: Text(e.value),
              selected: cur == e.key,
              onSelected: (_) => set(e.key),
            ),
        ]),
      );

  (String, List<Widget>) _panelContent(_P which) {
    final tr = player.state.tracks;
    final cur = player.state.track;
    switch (which) {
      case _P.subs:
        return ('Subtitles', [
          for (final t in tr.subtitle.where((t) => t.id != 'auto'))
            _row(_label(t, 'Subtitle'), on: t.id == cur.subtitle.id, onTap: () => _pickSub(t)),
          _row('Load subtitle file…', icon: Icons.folder_open, onTap: () {
            _closePanel();
            _loadSubFile();
          }),
          const Divider(height: 8),
          _stepper('Delay', '${subDelay.toStringAsFixed(1)} s', () {
            subDelay -= 0.1;
            _prop('sub-delay', subDelay.toStringAsFixed(2));
            _ss(() {});
          }, () {
            subDelay += 0.1;
            _prop('sub-delay', subDelay.toStringAsFixed(2));
            _ss(() {});
          }),
          _stepper('Size', '${(store.subScale * 100).round()}%', () {
            store.update(() => store.subScale = (store.subScale - 0.1).clamp(0.5, 2.0).toDouble());
            _applySubStyle();
            _ss(() {});
          }, () {
            store.update(() => store.subScale = (store.subScale + 0.1).clamp(0.5, 2.0).toDouble());
            _applySubStyle();
            _ss(() {});
          }),
          _stepper('Position', '${subPos.round()}', () {
            subPos = (subPos - 5).clamp(0.0, 150.0).toDouble();
            _applySubStyle();
            _ss(() {});
          }, () {
            subPos = (subPos + 5).clamp(0.0, 150.0).toDouble();
            _applySubStyle();
            _ss(() {});
          }),
          SwitchListTile(
            dense: true,
            title: const Text('Background box'),
            value: store.subBox,
            onChanged: (v) {
              store.update(() => store.subBox = v);
              _applySubStyle();
              _ss(() {});
            },
          ),
        ]);
      case _P.audio:
        return ('Audio', [
          for (final t in tr.audio.where((t) => t.id != 'auto' && t.id != 'no'))
            _row(_label(t, 'Audio'), on: t.id == cur.audio.id, onTap: () => _pickAudio(t)),
          const Divider(height: 8),
          _stepper('Delay', '${(audioDelay * 1000).round()} ms', () {
            audioDelay -= 0.05;
            _prop('audio-delay', audioDelay.toStringAsFixed(2));
            _ss(() {});
          }, () {
            audioDelay += 0.05;
            _prop('audio-delay', audioDelay.toStringAsFixed(2));
            _ss(() {});
          }),
        ]);
      case _P.speed:
        return ('Speed', [
          _chips<double>({for (final s in speeds) s: '$s×'}, rate, (v) {
            player.setRate(v);
            _flash('$v×');
          }),
          _stepper('Fine', '${rate.toStringAsFixed(2)}×', () {
            _stepSpeed(-1, fine: true);
            _ss(() {});
          }, () {
            _stepSpeed(1, fine: true);
            _ss(() {});
          }),
          _row('Make ${rate}× the default', icon: Icons.push_pin_outlined, onTap: () {
            store.update(() => store.defaultSpeed = rate);
            _flash('Default speed: ${rate}×');
          }),
        ]);
      case _P.chapters:
        final nowS = posN.value.inMilliseconds / 1000;
        var curI = -1;
        for (var i = 0; i < chapters.length; i++) {
          if (chapters[i].time <= nowS + 0.5) curI = i;
        }
        return ('Chapters', [
          for (var i = 0; i < chapters.length; i++)
            _row(
              chapters[i].title,
              on: i == curI,
              trailing: Text(fmt(Duration(seconds: chapters[i].time.round())),
                  style: const TextStyle(color: Colors.white60)),
              onTap: () {
                _seekTo(Duration(milliseconds: (chapters[i].time * 1000).round()));
                _ss(() {});
              },
            ),
        ]);
      case _P.sleep:
        return ('Sleep timer', [
          _chips<int>({0: 'Off', 15: '15 min', 30: '30 min', 45: '45 min', 60: '60 min', 90: '90 min'},
              sleepMin, _setSleep),
        ]);
      case _P.marks:
        final m = store.marksFor(_item);
        String t(double? x) => x == null ? '—' : fmt(Duration(seconds: x.round()));
        return (_item.isEpisode ? 'Intro & credits for this show' : 'Intro & credits', [
          _row('Intro: ${t(m.introStart)} → ${t(m.introEnd)}'),
          _row('Credits: ${m.creditsFromEnd == null ? '—' : '${m.creditsFromEnd!.round()} s before end'}'),
          _row('Intro starts here', icon: Icons.first_page, onTap: () {
            m.introStart = posN.value.inMilliseconds / 1000;
            store.saveMarks();
            _buildSegs();
            _ss(() {});
          }),
          _row('Intro ends here', icon: Icons.last_page, onTap: () {
            m.introEnd = posN.value.inMilliseconds / 1000;
            store.saveMarks();
            _buildSegs();
            _ss(() {});
          }),
          _row('Credits start here', icon: Icons.subtitles_off_outlined, onTap: () {
            final total = dur.inMilliseconds / 1000;
            if (total > 0) m.creditsFromEnd = total - posN.value.inMilliseconds / 1000;
            store.saveMarks();
            _ss(() {});
          }),
          _row('Clear', icon: Icons.clear, onTap: () {
            m.introStart = null;
            m.introEnd = null;
            m.creditsFromEnd = null;
            store.saveMarks();
            _buildSegs();
            _ss(() {});
          }),
        ]);
      case _P.queue:
        return ('Playlist · ${queue.length}', [
          for (var i = 0; i < queue.length; i++) _queueRow(i),
          if (!store.queue.contains(_item.path))
            _row('Add this to my Queue', icon: Icons.queue_play_next, onTap: () {
              store.addToQueue([_item.path]);
              _flash('Added to Queue');
              _ss(() {});
            }),
        ]);
      case _P.info:
        return ('Playback info', [
          for (final l in infoLines)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              child: Text(l, style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ),
          const SizedBox(height: 8),
        ]);
      case _P.more:
        return ('More', [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Zoom', style: TextStyle(color: Colors.white60, fontSize: 12)),
          ),
          _chips<BoxFit>({BoxFit.contain: 'Fit', BoxFit.cover: 'Fill', BoxFit.fill: 'Stretch'}, fit,
              (v) => _ss(() => fit = v)),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Aspect ratio', style: TextStyle(color: Colors.white60, fontSize: 12)),
          ),
          _chips<double>({0: 'Original', 16 / 9: '16:9', 4 / 3: '4:3', 21 / 9: '21:9'}, aspect ?? 0,
              (v) => _ss(() => aspect = v == 0 ? null : v)),
          SwitchListTile(
            dense: true,
            title: const Text('Loop this video'),
            value: loop,
            onChanged: (v) {
              loop = v;
              player.setPlaylistMode(v ? PlaylistMode.single : PlaylistMode.none);
              _ss(() {});
            },
          ),
          _row(sleepMin == 0 ? 'Sleep timer' : 'Sleep timer: $sleepMin min',
              icon: Icons.bedtime_outlined, onTap: () => _openPanel(_P.sleep)),
          _row('Mark intro & credits', icon: Icons.fast_forward_outlined, onTap: () => _openPanel(_P.marks)),
          if (_w < 600) ...[
            _row(landscapeLock ? 'Auto-rotate' : 'Lock to landscape', icon: Icons.screen_rotation, onTap: () {
              _ss(() => landscapeLock = !landscapeLock);
              _applyOrientation();
            }),
            _row('Lock controls', icon: Icons.lock_outline, onTap: () {
              _ss(() {
                locked = true;
                panel = null;
              });
              _poke();
            }),
          ],
          if (!isDesktop)
            _row('Picture in picture', icon: Icons.picture_in_picture_alt_outlined, onTap: () {
              _closePanel();
              Native.enterPip();
            }),
          _row('Save screenshot', icon: Icons.photo_camera_outlined, onTap: () {
            _closePanel();
            _shot();
          }),
          _row('Playback info', icon: Icons.info_outline, onTap: () {
            _loadInfo();
            _openPanel(_P.info);
          }),
        ]);
    }
  }

  Widget _queueRow(int i) {
    final it = queue[i];
    final cur = i == idx;
    final accent = Theme.of(context).colorScheme.primary;
    final d = store.durOf(it.path) ?? (cur && dur > Duration.zero ? dur.inMilliseconds : null);
    final watched = store.prog(it.path)?.watched == true;
    return Material(
      color: cur ? accent.withOpacity(0.16) : Colors.transparent,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: SizedBox(
          width: 26,
          child: cur
              ? Icon(Icons.play_arrow, color: accent, size: 20)
              : Text('${i + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: watched ? Colors.white38 : Colors.white70)),
        ),
        title: Text(
          it.isEpisode ? '${it.epLabel}${it.sub != null ? ' · ${it.sub}' : ''}' : it.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cur ? accent : (watched ? Colors.white54 : Colors.white),
            fontWeight: cur ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        trailing: Text(d == null ? '' : fmt(Duration(milliseconds: d)),
            style: const TextStyle(color: Colors.white60, fontSize: 12)),
        onTap: cur
            ? null
            : () {
                _save();
                _open(i);
                _ss(() {});
              },
      ),
    );
  }

  Widget _panel() {
    final which = panel;
    if (which == null) return const SizedBox.shrink();
    final (title, children) = _panelContent(which);
    final low = which == _P.queue;
    return Positioned(
      top: low ? null : _pad.top + 64,
      bottom: low ? _pad.bottom + (isDesktop ? 150 : 124) : null,
      right: 12 + _pad.right,
      child: Material(
        color: const Color(0xF21A1A21),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: low ? 420 : 340,
            minWidth: 240,
            maxHeight: (_h - _pad.top - (low ? 200 : 88)).clamp(120.0, 900.0).toDouble(),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
              child: Row(children: [
                Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: _closePanel),
              ]),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                controller: low ? _queueCtl : null,
                padding: const EdgeInsets.only(bottom: 8),
                children: children,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    _pad = MediaQuery.of(context).padding;
    final videoView = Video(
      controller: video,
      controls: NoVideoControls,
      fit: fit,
      aspectRatio: aspect,
      fill: Colors.black,
      subtitleViewConfiguration: store.libassOn
          ? const SubtitleViewConfiguration(visible: false)
          : SubtitleViewConfiguration(
              style: TextStyle(
                fontSize: 24 * store.subScale,
                height: 1.3,
                color: Colors.white,
                fontWeight: FontWeight.w500,
                backgroundColor: store.subBox ? const Color(0xA0000000) : null,
                shadows: store.subBox
                    ? null
                    : const [
                        Shadow(blurRadius: 2, color: Colors.black),
                        Shadow(blurRadius: 6, color: Colors.black87),
                      ],
              ),
              textAlign: TextAlign.center,
              padding: EdgeInsets.fromLTRB(32, 0, 32, 24 + (100 - subPos) * 2),
            ),
    );
    return ValueListenableBuilder<bool>(
      valueListenable: Native.pip,
      builder: (context, inPip, _) {
        if (inPip) return Scaffold(backgroundColor: Colors.black, body: videoView);
        return Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(builder: (context, box) {
            _w = box.maxWidth;
            _h = box.maxHeight;
            return _desktopWrap(GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _onTapUp,
              onLongPressStart: _lpStart,
              onLongPressEnd: _lpEnd,
              onHorizontalDragStart: _hStart,
              onHorizontalDragUpdate: _hUpdate,
              onHorizontalDragEnd: _hEnd,
              onVerticalDragStart: _vStart,
              onVerticalDragUpdate: _vUpdate,
              onVerticalDragEnd: (_) => _vMode = 0,
              child: Stack(fit: StackFit.expand, children: [
                Positioned.fill(child: IgnorePointer(child: videoView)),
                if (buffering)
                  const IgnorePointer(child: Center(child: CircularProgressIndicator())),
                ValueListenableBuilder<String?>(
                  valueListenable: osdN,
                  builder: (_, s, __) => s == null
                      ? const SizedBox.shrink()
                      : IgnorePointer(
                          child: Align(
                            alignment: const Alignment(0, -0.5),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.65),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(s,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: ui,
                  builder: (_, on, __) => Positioned.fill(
                    child: IgnorePointer(
                      ignoring: !on,
                      child: AnimatedOpacity(
                        opacity: on ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: locked ? _lockedOverlay() : _controls(),
                      ),
                    ),
                  ),
                ),
                // tiny persistent clock, bottom-left
                Positioned(
                  left: _pad.left + 10,
                  bottom: _pad.bottom + 4,
                  child: IgnorePointer(
                    child: ValueListenableBuilder<String>(
                      valueListenable: clockN,
                      builder: (_, t, __) => Text(t,
                          style: TextStyle(
                            fontSize: isDesktop ? 11 : 10,
                            color: Colors.white.withOpacity(0.35),
                            fontWeight: FontWeight.w500,
                          )),
                    ),
                  ),
                ),
                _skipButton(),
                _panel(),
              ]),
            ));
          }),
        );
      },
    );
  }

  Widget _skipButton() {
    return ValueListenableBuilder<bool>(
      valueListenable: ui,
      builder: (_, on, __) => ValueListenableBuilder<_Skip?>(
        valueListenable: skipN,
        builder: (_, s, __) {
          if (s == null || locked) return const SizedBox.shrink();
          return AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            right: 20 + _pad.right,
            bottom: (on ? 140 : 36) + _pad.bottom,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              onPressed: () {
                s.action();
                skipN.value = null;
              },
              icon: Icon(s.key == 'next' ? Icons.skip_next : Icons.fast_forward),
              label: Text(s.label, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          );
        },
      ),
    );
  }

  Widget _lockedOverlay() {
    return Align(
      alignment: Alignment.centerRight,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: IconButton.filledTonal(
            icon: const Icon(Icons.lock),
            onPressed: () {
              _ss(() => locked = false);
              _poke();
            },
          ),
        ),
      ),
    );
  }

  String? _chapterNow(Duration pos) {
    String? n;
    final s = pos.inMilliseconds / 1000;
    for (final c in chapters) {
      if (c.time <= s + 0.01) n = c.title;
    }
    return n;
  }

  Widget _controls() {
    const white = Colors.white;
    final it = _item;
    final multi = queue.length > 1;
    final wide = _w >= 600;
    final k = isDesktop ? 1.3 : 1.0;
    Widget ib(IconData i, VoidCallback? f, {String? tip, bool active = false}) => IconButton(
          tooltip: tip,
          iconSize: 24 * k,
          visualDensity: isDesktop ? VisualDensity.standard : VisualDensity.compact,
          icon: Icon(i, color: f == null ? Colors.white24 : (active ? Theme.of(context).colorScheme.primary : white)),
          onPressed: f,
        );
    void cycleFit() {
      final order = [BoxFit.contain, BoxFit.cover, BoxFit.fill];
      final n = order[(order.indexOf(fit) + 1) % order.length];
      _ss(() => fit = n);
      _flash(n == BoxFit.contain ? 'Fit' : (n == BoxFit.cover ? 'Fill' : 'Stretch'));
    }

    void rotate() {
      _ss(() => landscapeLock = !landscapeLock);
      _applyOrientation();
      _flash(landscapeLock ? 'Landscape' : 'Auto-rotate');
    }

    void lock() {
      _ss(() {
        locked = true;
        panel = null;
      });
      _poke();
    }

    final tools = <Widget>[
      if (chapters.isNotEmpty)
        ib(Icons.bookmarks_outlined, () => _openPanel(_P.chapters), tip: 'Chapters', active: panel == _P.chapters),
      ib(Icons.subtitles_outlined, () => _openPanel(_P.subs), tip: 'Subtitles', active: panel == _P.subs),
      ib(Icons.audiotrack_outlined, () => _openPanel(_P.audio), tip: 'Audio', active: panel == _P.audio),
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(44, 40), padding: const EdgeInsets.symmetric(horizontal: 6)),
        onPressed: () => _openPanel(_P.speed),
        child: Text('$rate×',
            style: TextStyle(
                color: panel == _P.speed ? Theme.of(context).colorScheme.primary : white,
                fontSize: 14 * k,
                fontWeight: FontWeight.w700)),
      ),
      if (isDesktop) ...[
        ib(fit == BoxFit.contain ? Icons.fit_screen_outlined : (fit == BoxFit.cover ? Icons.zoom_out_map : Icons.aspect_ratio),
            cycleFit, tip: 'Zoom'),
        ib(fs ? Icons.fullscreen_exit : Icons.fullscreen, _toggleFs, tip: 'Fullscreen (F)'),
      ] else if (wide) ...[
        ib(fit == BoxFit.contain ? Icons.fit_screen_outlined : (fit == BoxFit.cover ? Icons.zoom_out_map : Icons.aspect_ratio),
            cycleFit, tip: 'Zoom'),
        ib(landscapeLock ? Icons.screen_lock_landscape : Icons.screen_rotation, rotate, tip: 'Rotation'),
        ib(Icons.picture_in_picture_alt_outlined, () => Native.enterPip(), tip: 'Picture in picture'),
        ib(Icons.lock_open, lock, tip: 'Lock'),
      ],
      ib(Icons.more_vert, () => _openPanel(_P.more), tip: 'More', active: panel == _P.more),
    ];
    return Stack(children: [
      // top bar: title with all tools beside it
      Align(
        alignment: Alignment.topCenter,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 18),
              child: Row(children: [
                ib(Icons.arrow_back, () => Navigator.maybePop(context)),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: white, fontSize: 16 * k, fontWeight: FontWeight.w600)),
                    ValueListenableBuilder<Duration>(
                      valueListenable: posN,
                      builder: (_, pos, __) {
                        final left = dur - pos;
                        final ends = dur > Duration.zero
                            ? 'Ends at ${_clock(DateTime.now().add(Duration(milliseconds: (left.inMilliseconds / (rate <= 0 ? 1 : rate)).round())))}'
                            : '';
                        final parts = [if (it.detail.isNotEmpty) it.detail, if (ends.isNotEmpty) ends];
                        return Text(parts.join('  ·  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white70, fontSize: 12 * k));
                      },
                    ),
                  ]),
                ),
                ...tools,
              ]),
            ),
          ),
        ),
      ),
      // bottom bar: seek bar and playback buttons only
      Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 2),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SeekBar(
                  position: posN,
                  duration: dur,
                  chapters: chapters,
                  onStart: _scrubStart,
                  onChanged: _scrubUpdate,
                  onEnd: _scrubEnd,
                  onHover: _previewAt,
                  preview: pvN,
                ),
                ValueListenableBuilder<Duration>(
                  valueListenable: posN,
                  builder: (_, pos, __) {
                    final ch = _chapterNow(pos);
                    return Row(children: [
                      Text(fmt(pos), style: TextStyle(color: white, fontSize: 12 * k)),
                      Expanded(
                        child: Text(ch ?? '',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white60, fontSize: 12 * k)),
                      ),
                      Text('-${fmt(dur - pos < Duration.zero ? Duration.zero : dur - pos)}',
                          style: TextStyle(color: white, fontSize: 12 * k)),
                    ]);
                  },
                ),
                Row(children: [
                  const Expanded(child: SizedBox()),
                  if (multi)
                    ib(Icons.skip_previous, idx > 0
                        ? () {
                            _save();
                            _open(idx - 1);
                          }
                        : null),
                  ib(Icons.fast_rewind, () => _seekBy(-store.seekStep)),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    iconSize: 34 * k,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      player.playOrPause();
                      _poke();
                    },
                  ),
                  const SizedBox(width: 8),
                  ib(Icons.fast_forward, () => _seekBy(store.seekStep)),
                  if (multi)
                    ib(Icons.skip_next, _hasNext
                        ? () {
                            _save();
                            _open(idx + 1);
                          }
                        : null),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ib(Icons.playlist_play, () => _openPanel(_P.queue),
                          tip: 'Playlist', active: panel == _P.queue),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
