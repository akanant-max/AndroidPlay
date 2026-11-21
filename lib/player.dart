import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models.dart';
import 'store.dart';
import 'thumbs.dart';

const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0];

class PlayerPage extends StatefulWidget {
  final List<Item> queue;
  final int index;
  const PlayerPage({super.key, required this.queue, required this.index});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final Player player = Player(
    configuration: PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
  );
  late final VideoController video = VideoController(
    player,
    configuration: VideoControllerConfiguration(hwdec: store.hwdec),
  );

  final subs = <StreamSubscription>[];
  late int idx;
  final posN = ValueNotifier<Duration>(Duration.zero);
  final osdN = ValueNotifier<String?>(null);
  final ui = ValueNotifier<bool>(true);

  Duration dur = Duration.zero;
  bool playing = false,
      buffering = true,
      locked = false,
      scrubbing = false,
      landscapeLock = true,
      loop = false,
      hold = false;
  double rate = 1.0,
      _preBoost = 1.0,
      _vol = store.volume,
      _br = 0.5,
      subDelay = 0,
      audioDelay = 0,
      subSize = store.subSize;
  BoxFit fit = BoxFit.contain;
  double? aspect;
  List<Chap> chapters = [];
  int sleepMin = 0;

  Timer? hideT, saveT, osdT, sleepT, exactT, _tgtT;
  DateTime _lastSeek = DateTime(2000);
  Duration? _tgt;
  Duration _dragPos = Duration.zero;
  int _acc = 0, _vMode = 0;
  double _w = 1, _h = 1, _dtx = 0;

  void _ss(VoidCallback f) {
    if (mounted) setState(f);
  }

  // ------------------------------------------------------------ lifecycle

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    idx = widget.index;
    landscapeLock = store.landscape;
    thumbs.paused = true;
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _applyOrientation();
    _initBrightness();
    _tune();

    subs.addAll([
      player.stream.position.listen((v) {
        if (!scrubbing) posN.value = v;
      }),
      player.stream.duration.listen((v) {
        if (v != dur) {
          _ss(() => dur = v);
          if (v > Duration.zero) _loadChapters();
        }
      }),
      player.stream.playing.listen((v) {
        _ss(() => playing = v);
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
      player.stream.tracks.listen((_) => _ss(() {})),
      player.stream.track.listen((_) => _ss(() {})),
      player.stream.error.listen((e) => _flash('Error: $e', ms: 4000)),
    ]);

    saveT = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    _open(idx);
    _poke();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      player.pause();
      _save();
      store.flush();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _save();
    store.volume = _vol;
    store.flush();
    Future.microtask(store.touch);
    for (final s in subs) {
      s.cancel();
    }
    for (final t in [hideT, saveT, osdT, sleepT, exactT, _tgtT]) {
      t?.cancel();
    }
    player.dispose();
    WakelockPlus.disable();
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
    if (store.alang.isNotEmpty) await _prop('alang', store.alang);
    if (store.slang.isNotEmpty) await _prop('slang', store.slang);
    await player.setVolume(_vol);
  }

  Future<void> _loadChapters() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    try {
      final c = int.tryParse(await _get('chapter-list/count')) ?? 0;
      final out = <Chap>[];
      for (var i = 0; i < c; i++) {
        var t = await _get('chapter-list/$i/title');
        if (t.isEmpty) t = 'Chapter ${i + 1}';
        final tm = double.tryParse(await _get('chapter-list/$i/time')) ?? 0;
        out.add(Chap(t, tm));
      }
      _ss(() => chapters = out);
    } catch (_) {}
  }

  // ------------------------------------------------------------ playback

  Item get _item => widget.queue[idx];

  Future<void> _open(int i) async {
    idx = i;
    final it = _item;
    final pr = store.prog(it.path);
    Duration? start;
    if (store.resume &&
        pr != null &&
        !pr.watched &&
        pr.pos > 10000 &&
        pr.dur > 0 &&
        pr.pos < pr.dur * 0.95) {
      start = Duration(milliseconds: pr.pos - 2000);
    }
    dur = Duration.zero;
    posN.value = Duration.zero;
    chapters = [];
    subDelay = 0;
    audioDelay = 0;
    _ss(() {});
    await _prop('sub-delay', '0');
    await _prop('audio-delay', '0');
    await player.open(Media(it.path, start: start), play: true);
    if (start != null) _flash('Resumed at ${fmt(start)}');
  }

  void _save() {
    if (dur > Duration.zero) {
      store.setProg(_item.path, posN.value.inMilliseconds, dur.inMilliseconds);
    }
  }

  void _onCompleted() {
    if (dur > Duration.zero) {
      store.setProg(_item.path, dur.inMilliseconds, dur.inMilliseconds);
    }
    if (store.autoNext && idx + 1 < widget.queue.length) {
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

  void _seekBy(int secs) {
    if (_tgt == null) _acc = 0;
    _acc += secs;
    final t = _clampD((_tgt ?? posN.value) + Duration(seconds: secs));
    _tgt = t;
    _tgtT?.cancel();
    _tgtT = Timer(const Duration(milliseconds: 800), () => _tgt = null);
    posN.value = t;
    player.seek(t);
    _flash('${_acc > 0 ? '+' : ''}$_acc s   ${fmt(t)}');
  }

  void _scrubStart() {
    scrubbing = true;
    exactT?.cancel();
    if (!store.fastScrub) _hr('no');
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
    posN.value = t;
    player.seek(t);
  }

  void _setRate(double r) {
    player.setRate(r);
    _flash('${r}×');
  }

  // ------------------------------------------------------------ overlay UI

  void _flash(String s, {int ms = 1100}) {
    osdN.value = s;
    osdT?.cancel();
    osdT = Timer(Duration(milliseconds: ms), () => osdN.value = null);
  }

  void _poke() {
    ui.value = true;
    hideT?.cancel();
    if (playing && !hold) {
      hideT = Timer(const Duration(seconds: 3), () {
        if (playing && !hold) ui.value = false;
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

  // ------------------------------------------------------------ gestures

  void _doubleTap() {
    if (_dtx < _w / 3) {
      _seekBy(-store.seekStep);
    } else if (_dtx > _w * 2 / 3) {
      _seekBy(store.seekStep);
    } else {
      player.playOrPause();
    }
  }

  void _hStart(DragStartDetails d) {
    if (dur == Duration.zero) return;
    _dragPos = posN.value;
    _scrubStart();
  }

  void _hUpdate(DragUpdateDetails d) {
    if (dur == Duration.zero) return;
    _dragPos = _clampD(_dragPos + Duration(milliseconds: (d.delta.dx * 160).round()));
    _scrubUpdate(_dragPos);
    _flash('${fmt(_dragPos)} / ${fmt(dur)}', ms: 800);
  }

  void _hEnd(DragEndDetails d) {
    if (scrubbing) _scrubEnd(_dragPos);
  }

  void _vStart(DragStartDetails d) {
    _vMode = d.localPosition.dx < _w / 2 ? 1 : 2;
  }

  void _vUpdate(DragUpdateDetails d) {
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

  // ------------------------------------------------------------ sheets

  Future<void> _sheet(
    String title,
    List<Widget> Function(StateSetter ss, BuildContext c) build,
  ) async {
    hold = true;
    hideT?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF17171D),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (c) => SafeArea(
        child: StatefulBuilder(
          builder: (c, ss) => ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            ...build(ss, c),
          ]),
        ),
      ),
    );
    hold = false;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _poke();
  }

  String _label(dynamic t, String kind) {
    final id = t.id as String;
    if (id == 'no') return 'Off';
    if (id == 'auto') return 'Auto';
    final title = (t.title as String?) ?? '';
    final lang = (t.language as String?) ?? '';
    final parts = [if (title.isNotEmpty) title, if (lang.isNotEmpty) lang.toUpperCase()];
    return parts.isEmpty ? '$kind $id' : parts.join(' · ');
  }

  Widget _stepper(String label, String value, VoidCallback dec, VoidCallback inc) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: dec),
        SizedBox(width: 56, child: Text(value, textAlign: TextAlign.center)),
        IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: inc),
      ]),
    );
  }

  Future<void> _loadSubFile() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt', 'ass', 'ssa', 'vtt', 'sub'],
    );
    final path = r?.files.single.path;
    if (path != null) {
      await player.setSubtitleTrack(SubtitleTrack.uri(path));
      _flash('Subtitle loaded');
    }
  }

  void _subSheet() => _sheet('Subtitles', (ss, c) {
        final tr = player.state.tracks.subtitle;
        final cur = player.state.track.subtitle;
        return [
          for (final t in tr)
            ListTile(
              dense: true,
              title: Text(_label(t, 'Subtitle')),
              trailing: t.id == cur.id ? const Icon(Icons.check) : null,
              onTap: () {
                player.setSubtitleTrack(t);
                Navigator.pop(c);
              },
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_open),
            title: const Text('Load subtitle file…'),
            onTap: () async {
              Navigator.pop(c);
              await _loadSubFile();
            },
          ),
          _stepper('Delay', '${subDelay.toStringAsFixed(1)} s', () {
            subDelay -= 0.1;
            _prop('sub-delay', subDelay.toStringAsFixed(2));
            ss(() {});
          }, () {
            subDelay += 0.1;
            _prop('sub-delay', subDelay.toStringAsFixed(2));
            ss(() {});
          }),
          _stepper('Size', '${subSize.round()}', () {
            subSize = (subSize - 2).clamp(12.0, 60.0).toDouble();
            store.update(() => store.subSize = subSize);
            _ss(() {});
            ss(() {});
          }, () {
            subSize = (subSize + 2).clamp(12.0, 60.0).toDouble();
            store.update(() => store.subSize = subSize);
            _ss(() {});
            ss(() {});
          }),
        ];
      });

  void _audioSheet() => _sheet('Audio', (ss, c) {
        final tr = player.state.tracks.audio
            .where((t) => t.id != 'auto' && t.id != 'no')
            .toList();
        final cur = player.state.track.audio;
        return [
          for (final t in tr)
            ListTile(
              dense: true,
              title: Text(_label(t, 'Audio')),
              trailing: t.id == cur.id ? const Icon(Icons.check) : null,
              onTap: () {
                player.setAudioTrack(t);
                Navigator.pop(c);
              },
            ),
          _stepper('Delay', '${(audioDelay * 1000).round()} ms', () {
            audioDelay -= 0.05;
            _prop('audio-delay', audioDelay.toStringAsFixed(2));
            ss(() {});
          }, () {
            audioDelay += 0.05;
            _prop('audio-delay', audioDelay.toStringAsFixed(2));
            ss(() {});
          }),
        ];
      });

  void _speedSheet() => _sheet('Speed', (ss, c) => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (final s in _speeds)
              ChoiceChip(
                label: Text('$s×'),
                selected: rate == s,
                onSelected: (_) {
                  _setRate(s);
                  Navigator.pop(c);
                },
              ),
          ]),
        ),
      ]);

  void _chaptersSheet() => _sheet('Chapters', (ss, c) => [
        for (final ch in chapters)
          ListTile(
            dense: true,
            title: Text(ch.title),
            trailing: Text(fmt(Duration(seconds: ch.time.round()))),
            onTap: () {
              _seekTo(Duration(milliseconds: (ch.time * 1000).round()));
              Navigator.pop(c);
            },
          ),
      ]);

  void _seekTo(Duration t) {
    t = _clampD(t);
    posN.value = t;
    player.seek(t);
  }

  void _sleepSheet() => _sheet('Sleep timer', (ss, c) => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, children: [
            for (final m in [0, 15, 30, 45, 60, 90])
              ChoiceChip(
                label: Text(m == 0 ? 'Off' : '$m min'),
                selected: sleepMin == m,
                onSelected: (_) {
                  sleepMin = m;
                  sleepT?.cancel();
                  if (m > 0) {
                    sleepT = Timer(Duration(minutes: m), () {
                      _save();
                      if (mounted) Navigator.maybePop(context);
                    });
                  }
                  _flash(m == 0 ? 'Sleep timer off' : 'Stopping in $m min');
                  Navigator.pop(c);
                },
              ),
          ]),
        ),
      ]);

  void _moreSheet() => _sheet('More', (ss, c) => [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, children: [
            for (final e in {
              'Fit': BoxFit.contain,
              'Fill': BoxFit.cover,
              'Stretch': BoxFit.fill,
            }.entries)
              ChoiceChip(
                label: Text(e.key),
                selected: fit == e.value,
                onSelected: (_) {
                  _ss(() => fit = e.value);
                  ss(() {});
                },
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(spacing: 8, children: [
            for (final e in <String, double?>{
              'Original': null,
              '16:9': 16 / 9,
              '4:3': 4 / 3,
              '21:9': 21 / 9,
            }.entries)
              ChoiceChip(
                label: Text(e.key),
                selected: aspect == e.value,
                onSelected: (_) {
                  _ss(() => aspect = e.value);
                  ss(() {});
                },
              ),
          ]),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Loop this video'),
          value: loop,
          onChanged: (v) {
            loop = v;
            player.setPlaylistMode(v ? PlaylistMode.single : PlaylistMode.none);
            ss(() {});
          },
        ),
        if (chapters.isNotEmpty)
          ListTile(
            dense: true,
            leading: const Icon(Icons.list),
            title: Text('Chapters (${chapters.length})'),
            onTap: () {
              Navigator.pop(c);
              _chaptersSheet();
            },
          ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.bedtime_outlined),
          title: Text(sleepMin == 0 ? 'Sleep timer' : 'Sleep timer: $sleepMin min'),
          onTap: () {
            Navigator.pop(c);
            _sleepSheet();
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Save screenshot'),
          onTap: () {
            Navigator.pop(c);
            _shot();
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.info_outline),
          title: const Text('Playback info'),
          onTap: () {
            Navigator.pop(c);
            _info();
          },
        ),
      ]);

  Future<void> _shot() async {
    try {
      final b = await player.screenshot(format: 'image/png');
      if (b == null) return;
      final d = Directory('/storage/emulated/0/Pictures/Reel')
        ..createSync(recursive: true);
      final safe = _item.name.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), '');
      final f = File(p.join(
          d.path, '${safe}_${DateTime.now().millisecondsSinceEpoch}.png'));
      await f.writeAsBytes(b);
      _flash('Saved to Pictures/Reel');
    } catch (_) {
      _flash('Could not save screenshot');
    }
  }

  Future<void> _info() async {
    hold = true;
    final w = await _get('width'), h = await _get('height');
    final lines = <String>[
      'Video: ${await _get('video-format')} ${w}x$h @ ${await _get('container-fps')} fps',
      'Decoder: ${await _get('hwdec-current')} (setting: ${store.hwdec})',
      'Audio: ${await _get('audio-codec-name')}',
      'Container: ${await _get('file-format')}',
      'Dropped frames: ${await _get('frame-drop-count')} (decoder: ${await _get('decoder-frame-drop-count')})',
    ];
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Playback info'),
        content: Text(lines.join('\n'), style: const TextStyle(height: 1.6)),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
    hold = false;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _poke();
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final it = _item;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, box) {
        _w = box.maxWidth;
        _h = box.maxHeight;
        return Stack(children: [
          Positioned.fill(
            child: Video(
              controller: video,
              controls: NoVideoControls,
              fit: fit,
              aspectRatio: aspect,
              fill: Colors.black,
              subtitleViewConfiguration: SubtitleViewConfiguration(
                style: TextStyle(
                  fontSize: subSize,
                  height: 1.25,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: const [
                    Shadow(blurRadius: 3, color: Colors.black, offset: Offset(1, 1)),
                    Shadow(blurRadius: 3, color: Colors.black, offset: Offset(-1, -1)),
                  ],
                ),
                textAlign: TextAlign.center,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              ),
            ),
          ),
          Positioned.fill(child: _gestures()),
          if (buffering)
            const IgnorePointer(child: Center(child: CircularProgressIndicator())),
          ValueListenableBuilder<String?>(
            valueListenable: osdN,
            builder: (_, s, __) => s == null
                ? const SizedBox.shrink()
                : IgnorePointer(
                    child: Align(
                      alignment: const Alignment(0, -0.55),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(s,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: ui,
            builder: (_, on, __) => IgnorePointer(
              ignoring: !on,
              child: AnimatedOpacity(
                opacity: on ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: locked ? _lockedOverlay() : _controls(it),
              ),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _gestures() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleUi,
      onDoubleTapDown: locked ? null : (d) => _dtx = d.localPosition.dx,
      onDoubleTap: locked ? null : _doubleTap,
      onLongPressStart: locked
          ? null
          : (_) {
              _preBoost = rate;
              player.setRate(2.0);
              _flash('2× speed', ms: 60000);
            },
      onLongPressEnd: locked
          ? null
          : (_) {
              player.setRate(_preBoost);
              osdN.value = null;
            },
      onHorizontalDragStart: locked ? null : _hStart,
      onHorizontalDragUpdate: locked ? null : _hUpdate,
      onHorizontalDragEnd: locked ? null : _hEnd,
      onVerticalDragStart: locked ? null : _vStart,
      onVerticalDragUpdate: locked ? null : _vUpdate,
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

  Widget _controls(Item it) {
    const white = Colors.white;
    final multi = widget.queue.length > 1;
    return Stack(children: [
      // top bar
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
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
              child: Row(children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: white),
                  onPressed: () => Navigator.maybePop(context),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: white, fontSize: 16, fontWeight: FontWeight.w600)),
                    if (it.detail.isNotEmpty)
                      Text(it.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
                ),
                IconButton(
                  icon: const Icon(Icons.subtitles_outlined, color: white),
                  onPressed: _subSheet,
                ),
                IconButton(
                  icon: const Icon(Icons.audiotrack_outlined, color: white),
                  onPressed: _audioSheet,
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert, color: white),
                  onPressed: _moreSheet,
                ),
              ]),
            ),
          ),
        ),
      ),
      // bottom bar
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
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ValueListenableBuilder<Duration>(
                  valueListenable: posN,
                  builder: (context, pos, _) {
                    final total = dur.inMilliseconds;
                    final v = total > 0
                        ? (pos.inMilliseconds / total).clamp(0.0, 1.0).toDouble()
                        : 0.0;
                    return Row(children: [
                      SizedBox(
                        width: 52,
                        child: Text(fmt(pos),
                            style: const TextStyle(color: white, fontSize: 12)),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape:
                                const RoundSliderThumbShape(enabledThumbRadius: 7),
                            overlayShape:
                                const RoundSliderOverlayShape(overlayRadius: 16),
                          ),
                          child: Slider(
                            value: v,
                            onChangeStart: total > 0 ? (_) => _scrubStart() : null,
                            onChanged: total > 0
                                ? (x) => _scrubUpdate(
                                    Duration(milliseconds: (x * total).round()))
                                : null,
                            onChangeEnd: total > 0
                                ? (x) => _scrubEnd(
                                    Duration(milliseconds: (x * total).round()))
                                : null,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(fmt(dur),
                            textAlign: TextAlign.right,
                            style: const TextStyle(color: white, fontSize: 12)),
                      ),
                    ]);
                  },
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  IconButton(
                    tooltip: 'Lock controls',
                    icon: const Icon(Icons.lock_open, color: white),
                    onPressed: () {
                      _ss(() => locked = true);
                      _poke();
                    },
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_previous,
                        color: multi && idx > 0 ? white : Colors.white24),
                    onPressed: multi && idx > 0
                        ? () {
                            _save();
                            _open(idx - 1);
                          }
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.fast_rewind, color: white),
                    onPressed: () => _seekBy(-store.seekStep),
                  ),
                  IconButton.filled(
                    iconSize: 34,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      player.playOrPause();
                      _poke();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.fast_forward, color: white),
                    onPressed: () => _seekBy(store.seekStep),
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_next,
                        color: multi && idx + 1 < widget.queue.length
                            ? white
                            : Colors.white24),
                    onPressed: multi && idx + 1 < widget.queue.length
                        ? () {
                            _save();
                            _open(idx + 1);
                          }
                        : null,
                  ),
                  TextButton(
                    onPressed: _speedSheet,
                    child: Text('$rate×',
                        style: const TextStyle(color: white, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: 'Rotation',
                    icon: Icon(
                        landscapeLock
                            ? Icons.screen_lock_landscape
                            : Icons.screen_rotation,
                        color: white),
                    onPressed: () {
                      _ss(() => landscapeLock = !landscapeLock);
                      _applyOrientation();
                      _flash(landscapeLock ? 'Landscape' : 'Auto-rotate');
                    },
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
