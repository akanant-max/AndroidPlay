import 'package:flutter/material.dart';

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
            sw('Open videos in landscape', store.landscape, (v) => store.landscape = v),
            sw('Picture-in-picture when leaving the app', store.autoPip, (v) => store.autoPip = v),
            drop<String>('Hardware decoding', store.hwdec, {
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
            head('Player gestures'),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 32),
              child: Text(
                'Tap: show or hide controls\n'
                'Double-tap left or right: skip back or forward (keep tapping to skip more)\n'
                'Double-tap middle: play or pause\n'
                'Swipe left or right: scrub\n'
                'Swipe up or down on the left: brightness\n'
                'Swipe up or down on the right: volume (up to 130%)\n'
                'Press and hold: 2× speed while held',
                style: TextStyle(color: Colors.white60, height: 1.5),
              ),
            ),
          ]),
        );
      },
    );
  }
}
