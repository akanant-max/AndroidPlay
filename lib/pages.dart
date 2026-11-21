import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'store.dart';
import 'thumbs.dart';
import 'widgets.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  static const _pages = <Widget>[
    HomePage(),
    LibraryPage(shows: false),
    LibraryPage(shows: true),
    FoldersPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        ListenableBuilder(
          listenable: store,
          builder: (_, __) => SizedBox(
            height: 2,
            child: store.scanning ? const LinearProgressIndicator() : null,
          ),
        ),
        Expanded(child: IndexedStack(index: tab, children: _pages)),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: 'Movies'),
          NavigationDestination(icon: Icon(Icons.tv_outlined), selectedIcon: Icon(Icons.tv), label: 'Shows'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'Library'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Home

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reel')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (store.items.isEmpty) {
            return const EmptyState(
              Icons.video_library_outlined,
              'Add a folder and your movies and shows appear here.',
              addButton: true,
            );
          }
          final cont = store.continueWatching();
          final next = store.nextUp();
          final recent = store.recent();
          return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
            if (cont.isNotEmpty)
              Shelf('Continue watching', [for (final i in cont) itemCard(context, i)]),
            if (next.isNotEmpty)
              Shelf('Next up', [for (final i in next) itemCard(context, i, showProgress: false)]),
            if (recent.isNotEmpty)
              Shelf('Recently added', [for (final i in recent) itemCard(context, i)]),
          ]);
        },
      ),
    );
  }
}

// ------------------------------------------------------- Movies / Shows

class _Tile {
  final String title;
  final String? subtitle;
  final Item art;
  final String? artPath;
  final double progress;
  final bool watched, anyUnwatched;
  final int badge, added, year;
  final VoidCallback onTap;
  final VoidCallback? onLong;
  _Tile({
    required this.title,
    this.subtitle,
    required this.art,
    this.artPath,
    this.progress = 0,
    this.watched = false,
    this.anyUnwatched = true,
    this.badge = 0,
    required this.added,
    this.year = 0,
    required this.onTap,
    this.onLong,
  });
}

class LibraryPage extends StatefulWidget {
  final bool shows;
  const LibraryPage({super.key, required this.shows});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String q = '';
  bool searching = false, unwatchedOnly = false;
  int sort = 0;

  List<_Tile> _tiles(BuildContext context) {
    final out = <_Tile>[];
    if (!widget.shows) {
      for (final i in store.movies) {
        final pr = store.prog(i.path);
        out.add(_Tile(
          title: i.name,
          subtitle: null,
          art: i,
          progress: pr != null && !pr.watched ? pr.frac : 0,
          watched: pr?.watched ?? false,
          anyUnwatched: pr?.watched != true,
          added: i.added,
          year: i.year ?? 0,
          onTap: () => playItem(context, i),
          onLong: () => itemSheet(context, i),
        ));
      }
    } else {
      store.shows.forEach((key, eps) {
        final unwatched =
            eps.where((e) => store.prog(e.path)?.watched != true).length;
        final seasons = eps.map((e) => e.season).toSet().length;
        out.add(_Tile(
          title: eps.first.show!,
          subtitle:
              '${eps.length} episode${eps.length == 1 ? '' : 's'} · $seasons season${seasons == 1 ? '' : 's'}',
          art: eps.first,
          artPath: showArt(eps),
          watched: unwatched == 0,
          anyUnwatched: unwatched > 0,
          badge: unwatched == eps.length ? 0 : unwatched,
          added: eps.map((e) => e.added).reduce((a, b) => a > b ? a : b),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ShowPage(name: eps.first.show!, keyName: key),
          )),
        ));
      });
    }
    var list = out.where((t) {
      if (q.isNotEmpty && !t.title.toLowerCase().contains(q)) return false;
      if (unwatchedOnly && !t.anyUnwatched) return false;
      return true;
    }).toList();
    list.sort((a, b) {
      switch (sort) {
        case 1:
          return b.added.compareTo(a.added);
        case 2:
          final c = b.year.compareTo(a.year);
          if (c != 0) return c;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        default:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      }
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tiles = _tiles(context);
        return Scaffold(
          appBar: AppBar(
            title: searching
                ? TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                        hintText: 'Search', border: InputBorder.none),
                    onChanged: (v) => setState(() => q = v.trim().toLowerCase()),
                  )
                : Text(widget.shows ? 'TV Shows' : 'Movies'),
            actions: [
              IconButton(
                icon: Icon(searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  searching = !searching;
                  if (!searching) q = '';
                }),
              ),
              IconButton(
                tooltip: 'Unwatched only',
                icon: Icon(unwatchedOnly
                    ? Icons.visibility
                    : Icons.visibility_outlined),
                onPressed: () => setState(() => unwatchedOnly = !unwatchedOnly),
              ),
              PopupMenuButton<int>(
                icon: const Icon(Icons.sort),
                onSelected: (v) => setState(() => sort = v),
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(value: 0, checked: sort == 0, child: const Text('Title')),
                  CheckedPopupMenuItem(value: 1, checked: sort == 1, child: const Text('Recently added')),
                  if (!widget.shows)
                    CheckedPopupMenuItem(value: 2, checked: sort == 2, child: const Text('Year')),
                ],
              ),
            ],
          ),
          body: tiles.isEmpty
              ? EmptyState(
                  widget.shows ? Icons.tv_outlined : Icons.movie_outlined,
                  store.items.isEmpty
                      ? 'Add a folder in the Library tab.'
                      : 'Nothing matches.',
                )
              : LayoutBuilder(builder: (context, c) {
                  final cols = (c.maxWidth / 190).floor().clamp(2, 6);
                  final w = (c.maxWidth - 32 - (cols - 1) * 12) / cols;
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 12,
                      mainAxisExtent: w * 9 / 16 + 54,
                    ),
                    itemCount: tiles.length,
                    itemBuilder: (_, i) {
                      final t = tiles[i];
                      return MediaCard(
                        title: t.title,
                        subtitle: t.subtitle,
                        artItem: t.art,
                        artPath: t.artPath,
                        progress: t.progress,
                        watched: t.watched,
                        badge: t.badge,
                        onTap: t.onTap,
                        onLong: t.onLong,
                      );
                    },
                  );
                }),
        );
      },
    );
  }
}

// ----------------------------------------------------------- Show page

class ShowPage extends StatefulWidget {
  final String name, keyName;
  const ShowPage({super.key, required this.name, required this.keyName});
  @override
  State<ShowPage> createState() => _ShowPageState();
}

class _ShowPageState extends State<ShowPage> {
  int? season;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final eps = store.shows[widget.keyName] ?? <Item>[];
        final seasons = eps.map((e) => e.season!).toSet().toList()..sort();
        final sel = (season != null && seasons.contains(season))
            ? season
            : (seasons.isEmpty ? null : seasons.first);
        final list = eps.where((e) => e.season == sel).toList();
        final ri = eps.isEmpty ? 0 : store.resumeIndex(eps);
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.name),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) {
                  for (final e in eps) {
                    store.progress
                        .putIfAbsent(e.path, () => Prog())
                        .watched = v == 'w';
                    if (v != 'w') store.progress[e.path]!.pos = 0;
                  }
                  store.touch();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'w', child: Text('Mark all watched')),
                  PopupMenuItem(value: 'u', child: Text('Mark all unwatched')),
                ],
              ),
            ],
          ),
          body: eps.isEmpty
              ? const EmptyState(Icons.tv_outlined, 'No episodes found.')
              : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(children: [
                      FilledButton.icon(
                        onPressed: () => playItems(context, eps, ri),
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                            '${store.prog(eps[ri].path)?.pos != null && (store.prog(eps[ri].path)!.pos > 15000) ? 'Resume' : 'Play'} ${eps[ri].epLabel}'),
                      ),
                    ]),
                  ),
                  if (seasons.length > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Wrap(spacing: 8, children: [
                        for (final s in seasons)
                          ChoiceChip(
                            label: Text(s == 0 ? 'Specials' : 'Season $s'),
                            selected: s == sel,
                            onSelected: (_) => setState(() => season = s),
                          ),
                      ]),
                    ),
                  for (final e in list) _episode(context, e, eps),
                ]),
        );
      },
    );
  }

  Widget _episode(BuildContext context, Item e, List<Item> all) {
    final pr = store.prog(e.path);
    final inProg = pr != null && !pr.watched && pr.pos > 15000;
    final status = pr?.watched == true
        ? 'Watched'
        : inProg
            ? '${fmt(Duration(milliseconds: pr!.pos))} / ${fmt(Duration(milliseconds: pr.dur))}'
            : fmtSize(e.size);
    return InkWell(
      onTap: () => playItems(context, all, all.indexOf(e)),
      onLongPress: () => itemSheet(context, e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          SizedBox(
            width: 140,
            child: ArtThumb(
              item: e,
              progress: inProg ? pr!.frac : 0,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'E${e.episode} · ${e.sub ?? 'Episode ${e.episode}'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(status,
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
            ]),
          ),
          IconButton(
            icon: Icon(
              pr?.watched == true
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: pr?.watched == true ? null : Colors.white38,
            ),
            onPressed: () => store.markWatched(e.path, pr?.watched != true),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------- Library

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key});

  static const _quick = [
    '/storage/emulated/0/Movies',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/DCIM',
    '/storage/emulated/0/Videos',
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, thumbs]),
      builder: (context, _) {
        final quick = [
          for (final d in _quick)
            if (!store.folders.contains(d) && Directory(d).existsSync()) d
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Library'),
            actions: [
              IconButton(
                tooltip: 'Rescan',
                icon: const Icon(Icons.refresh),
                onPressed: store.scanning ? null : () => store.rescan(ask: true),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => addFolderFlow(context),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Add folder'),
          ),
          body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: Text('${store.items.length} videos · '
                  '${store.movies.length} movies · ${store.shows.length} shows'),
              subtitle: Text(store.scanning
                  ? 'Scanning…'
                  : thumbs.pending > 0
                      ? 'Making thumbnails: ${thumbs.pending} left'
                      : 'Up to date'),
            ),
            const Divider(height: 1),
            if (store.folders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No folders yet. Add the folders where your videos live. '
                  'Reel only reads this phone\'s storage, nothing goes online.',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
            for (final f in store.folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(p.basename(f).isEmpty ? f : p.basename(f)),
                subtitle: Text(
                  '$f\n${store.items.where((i) => p.isWithin(f, i.path)).length} videos'
                  '${Directory(f).existsSync() ? '' : ' · not found'}',
                ),
                isThreeLine: true,
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => store.removeFolder(f),
                ),
              ),
            if (quick.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text('Quick add', style: TextStyle(color: Colors.white60)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  for (final d in quick)
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: Text(p.basename(d)),
                      onPressed: () => store.addFolder(d),
                    ),
                ]),
              ),
            ],
          ]),
        );
      },
    );
  }
}

// ------------------------------------------------------------ Settings

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
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700)),
            );
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(children: [
            head('Playback'),
            ListTile(
              title: const Text('Hardware decoding'),
              subtitle: const Text('Change only if a video stutters or shows green'),
              trailing: DropdownButton<String>(
                value: store.hwdec,
                underline: const SizedBox(),
                onChanged: (v) => store.update(() => store.hwdec = v!),
                items: const [
                  DropdownMenuItem(value: 'auto-safe', child: Text('Auto')),
                  DropdownMenuItem(value: 'mediacodec', child: Text('MediaCodec')),
                  DropdownMenuItem(value: 'mediacodec-copy', child: Text('MediaCodec copy')),
                  DropdownMenuItem(value: 'no', child: Text('Software')),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Always use fast seeking'),
              subtitle: const Text(
                  'Jumps to the nearest keyframe: smoothest on 4K, slightly less exact. Dragging the bar is always fast.'),
              value: store.fastScrub,
              onChanged: (v) => store.update(() => store.fastScrub = v),
            ),
            SwitchListTile(
              title: const Text('Resume where I left off'),
              value: store.resume,
              onChanged: (v) => store.update(() => store.resume = v),
            ),
            SwitchListTile(
              title: const Text('Play next episode automatically'),
              value: store.autoNext,
              onChanged: (v) => store.update(() => store.autoNext = v),
            ),
            SwitchListTile(
              title: const Text('Open videos in landscape'),
              value: store.landscape,
              onChanged: (v) => store.update(() => store.landscape = v),
            ),
            ListTile(
              title: const Text('Double-tap skip'),
              trailing: DropdownButton<int>(
                value: store.seekStep,
                underline: const SizedBox(),
                onChanged: (v) => store.update(() => store.seekStep = v!),
                items: [
                  for (final s in [5, 10, 15, 30])
                    DropdownMenuItem(value: s, child: Text('$s s')),
                ],
              ),
            ),
            head('Subtitles and audio'),
            ListTile(
              title: Text('Subtitle size: ${store.subSize.round()}'),
              subtitle: Slider(
                min: 14, max: 48, divisions: 34,
                value: store.subSize.clamp(14.0, 48.0).toDouble(),
                onChanged: (v) => store.update(() => store.subSize = v),
              ),
            ),
            ListTile(
              title: const Text('Preferred audio languages'),
              subtitle: TextFormField(
                initialValue: store.alang,
                decoration: const InputDecoration(hintText: 'e.g. eng,hin'),
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
            SwitchListTile(
              title: const Text('Rescan folders when the app opens'),
              value: store.scanOnStart,
              onChanged: (v) => store.update(() => store.scanOnStart = v),
            ),
            SwitchListTile(
              title: const Text('Make thumbnails from video frames'),
              subtitle: const Text('Runs one at a time and pauses while you watch'),
              value: store.thumbsOn,
              onChanged: (v) {
                store.update(() => store.thumbsOn = v);
                if (v) thumbs.resume();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Clear thumbnail cache'),
              onTap: () {
                thumbs.clearAll();
                for (final i in store.items) {
                  thumbs.want(i);
                }
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Thumbnails will be rebuilt')));
              },
            ),
            head('Player gestures'),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: Text(
                'Tap: show or hide controls\n'
                'Double-tap left or right: skip back or forward\n'
                'Double-tap middle: play or pause\n'
                'Swipe left or right: scrub\n'
                'Swipe up or down on the left: brightness\n'
                'Swipe up or down on the right: volume (up to 130%)\n'
                'Press and hold: 2x speed while held',
                style: TextStyle(color: Colors.white60, height: 1.5),
              ),
            ),
          ]),
        );
      },
    );
  }
}
