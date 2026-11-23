import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform.dart';
import 'store.dart';
import 'thumbs.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        Widget head(String t) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(t,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
            );
        Widget drop<T>(String title, T value, Map<T, String> opts, void Function(T) set,
                {String? sub}) =>
            ListTile(
              title: Text(title),
              subtitle: sub == null ? null : Text(sub),
              trailing: DropdownButton<T>(
                value: opts.containsKey(value) ? value : opts.keys.first,
                underline: const SizedBox(),
                onChanged: (v) {
                  if (v != null) store.update(() => set(v));
                },
                items: [
                  for (final e in opts.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
              ),
            );
        Widget sw(String title, bool v, void Function(bool) set, {String? sub}) => SwitchListTile(
              title: Text(title),
              subtitle: sub == null ? null : Text(sub),
              value: v,
              onChanged: (x) => store.update(() => set(x)),
            );
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(children: [
            head('Playback'),
            drop<double>('Default speed', store.defaultSpeed,
                {for (final s in speeds) s: '$s×'}, (v) => store.defaultSpeed = v),
            sw('Resume where I left off', store.resume, (v) => store.resume = v),
            sw('Play next episode automatically', store.autoNext, (v) => store.autoNext = v),
            sw('Skip intros and recaps automatically', store.autoSkipIntro, (v) => store.autoSkipIntro = v,
                sub: 'Uses chapter names (OP, Intro, Recap) or the intro you marked for a show'),
            drop<int>('Show "Next episode" button', store.nextBeforeEnd,
                {0: 'Only at credits', 30: 'Last 30 s', 60: 'Last 60 s', 90: 'Last 90 s', 120: 'Last 2 min'},
                (v) => store.nextBeforeEnd = v,
                sub: 'Used when the file has no credits chapter'),
            drop<int>('Double-tap skip', store.seekStep,
                {for (final s in [5, 10, 15, 30]) s: '$s s'}, (v) => store.seekStep = v),
            if (!isDesktop) ...[
              sw('Open videos in landscape', store.landscape, (v) => store.landscape = v),
              sw('Picture-in-picture when leaving the app', store.autoPip, (v) => store.autoPip = v),
            ],
            drop<String>('Hardware decoding', store.hwdec, isDesktop
                ? {
                    'auto-safe': 'Auto',
                    'd3d11va': 'D3D11',
                    'd3d11va-copy': 'D3D11 copy',
                    'no': 'Software',
                  }
                : {
                    'auto-safe': 'Auto',
                    'mediacodec': 'MediaCodec',
                    'mediacodec-copy': 'MediaCodec copy',
                    'no': 'Software',
                  }, (v) => store.hwdec = v, sub: 'Change only if a video stutters or shows green'),
            sw('Always use fast seeking', store.fastScrub, (v) => store.fastScrub = v,
                sub: 'Jumps to the nearest keyframe. Dragging the bar is always fast.'),
            head('Subtitles and audio'),
            ListTile(
              title: Text('Subtitle size: ${(store.subScale * 100).round()}%'),
              subtitle: Slider(
                min: 0.5, max: 2.0, divisions: 30,
                value: store.subScale.clamp(0.5, 2.0).toDouble(),
                onChanged: (v) => store.update(() => store.subScale = v),
              ),
            ),
            sw('Full subtitle renderer (libass)', store.libassOn, (v) => store.libassOn = v,
                sub: 'Keeps styled anime subtitles and Blu-ray picture subtitles. Turn off if the player crashes.'),
            sw('Subtitle background box', store.subBox, (v) => store.subBox = v,
                sub: 'Dark box behind text instead of an outline'),
            ListTile(
              title: const Text('Preferred audio languages'),
              subtitle: TextFormField(
                initialValue: store.alang,
                decoration: const InputDecoration(hintText: 'e.g. jpn,eng,hin'),
                onChanged: (v) => store.update(() => store.alang = v.trim()),
              ),
            ),
            ListTile(
              title: const Text('Preferred subtitle languages'),
              subtitle: TextFormField(
                initialValue: store.slang,
                decoration: const InputDecoration(hintText: 'e.g. eng,ben'),
                onChanged: (v) => store.update(() => store.slang = v.trim()),
              ),
            ),
            head('Library'),
            sw('Scan for changes when the app opens', store.scanOnStart, (v) => store.scanOnStart = v),
            sw('Make thumbnails from video frames', store.thumbsOn, (v) {
              store.thumbsOn = v;
              if (v) thumbs.resume();
            }, sub: 'One at a time, paused while you watch'),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Rebuild thumbnails'),
              onTap: () {
                thumbs.clearAll();
                for (final i in store.items) {
                  thumbs.want(i);
                }
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Thumbnails will be rebuilt')));
              },
            ),
            if (store.hidden.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: Text('Unhide ${store.hidden.length} hidden videos'),
                onTap: store.unhideAll,
              ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Error log'),
              subtitle: const Text('Copy this and send it if something breaks'),
              onTap: () {
                var text = '';
                try {
                  text = store.errorLog.existsSync() ? store.errorLog.readAsStringSync() : '';
                } catch (_) {}
                if (text.isEmpty) text = 'No errors logged.';
                showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Error log'),
                    content: SizedBox(
                      width: 500,
                      child: SingleChildScrollView(
                        child: SelectableText(text, style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          try {
                            store.errorLog.deleteSync();
                          } catch (_) {}
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear'),
                      ),
                      FilledButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: text));
                          Navigator.pop(ctx);
                        },
                        child: const Text('Copy'),
                      ),
                    ],
                  ),
                );
              },
            ),
            head(isDesktop ? 'Player shortcuts' : 'Player gestures'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              child: Text(
                isDesktop ? desktopShortcuts : 'Tap: show or hide controls\n'
                'Double-tap left or right: skip back or forward (keep tapping to skip more)\n'
                'Double-tap middle: play or pause\n'
                'Swipe left or right: scrub\n'
                'Swipe up or down on the left: brightness\n'
                'Swipe up or down on the right: volume (up to 130%)\n'
                'Press and hold: 2× speed while held',
                style: const TextStyle(color: Colors.white60, height: 1.5),
              ),
            ),
          ]),
        );
      },
    );
  }
}

const desktopShortcuts = 'Click: play / pause    Double-click or F: fullscreen    Esc: exit fullscreen / back\n'
    'Space or K: play / pause\n'
    '← →: skip (Shift: 60 s, Ctrl: 3 s)    J / L: 10 s back / forward\n'
    '↑ ↓ or mouse wheel: volume    M: mute\n'
    '[ ]: slower / faster    \\: normal speed\n'
    'S: next subtitle    A: next audio track    C: chapters    I: playback info\n'
    'N / P: next / previous episode    , .: frame back / forward (paused)\n'
    '0–9: jump to 0–90%    Ctrl+S: screenshot\n'
    'Drag across the video: scrub    Hold mouse: 2× speed';
