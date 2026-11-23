import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'collections.dart';
import 'models.dart';
import 'settings.dart';
import 'sources.dart';
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
    CollectionPage(id: null),
    SourcesPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final body = Column(children: [
      ListenableBuilder(
        listenable: store,
        builder: (_, __) => SizedBox(
          height: 2,
          child: store.scanning ? const LinearProgressIndicator() : null,
        ),
      ),
      Expanded(child: IndexedStack(index: tab, children: _pages)),
    ]);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            labelType: NavigationRailLabelType.all,
            backgroundColor: const Color(0xFF14141A),
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('AURA', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
            ),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: Text('Home')),
              NavigationRailDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: Text('Movies')),
              NavigationRailDestination(icon: Icon(Icons.tv_outlined), selectedIcon: Icon(Icons.tv), label: Text('Shows')),
              NavigationRailDestination(icon: Icon(Icons.folder_special_outlined), selectedIcon: Icon(Icons.folder_special), label: Text('Folders')),
              NavigationRailDestination(icon: Icon(Icons.storage_outlined), selectedIcon: Icon(Icons.storage), label: Text('Sources')),
            ],
          ),
          Expanded(child: body),
        ]),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: 'Movies'),
          NavigationDestination(icon: Icon(Icons.tv_outlined), selectedIcon: Icon(Icons.tv), label: 'Shows'),
          NavigationDestination(icon: Icon(Icons.folder_special_outlined), selectedIcon: Icon(Icons.folder_special), label: 'Folders'),
          NavigationDestination(icon: Icon(Icons.storage_outlined), selectedIcon: Icon(Icons.storage), label: 'Sources'),
        ],
      ),
    );
  }
}

Widget rescanButton() => ListenableBuilder(
      listenable: store,
      builder: (_, __) => IconButton(
        tooltip: 'Scan for changes',
        icon: const Icon(Icons.refresh),
        onPressed: store.scanning ? null : () => store.rescan(ask: true),
      ),
    );

// ---------------------------------------------------------------- Home

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final sel = <String>{};

  void _toggle(String id) => setState(() => sel.contains(id) ? sel.remove(id) : sel.add(id));

  @override
  Widget build(BuildContext context) {
    final notice = store.crashNotice;
    if (notice != null) {
      store.crashNotice = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(notice),
          duration: const Duration(seconds: 8),
        ));
      });
    }
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        sel.removeWhere((x) => !store.byPath.containsKey(x));
        final selecting = sel.isNotEmpty;
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (_, __) {
            if (selecting) setState(sel.clear);
          },
          child: Scaffold(
            appBar: selecting
                ? selectionBar(context, sel, clear: () => setState(sel.clear))
                : AppBar(
                    title: const Text('AURA'),
                    actions: [
                      IconButton(
                        tooltip: 'Search',
                        icon: const Icon(Icons.search),
                        onPressed: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const SearchPage())),
                      ),
                      IconButton(
                        tooltip: 'All videos',
                        icon: const Icon(Icons.video_library_outlined),
                        onPressed: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const AllVideosPage())),
                      ),
                      rescanButton(),
                      IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
                      ),
                    ],
                  ),
            body: Builder(builder: (context) {
              if (store.items.isEmpty) {
                return EmptyState(
                  Icons.video_library_outlined,
                  'Add a folder or some files and your movies and shows appear here.',
                  action: FilledButton.icon(
                    onPressed: () => openBrowser(context),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Add videos'),
                  ),
                );
              }
              final cont = store.continueWatching();
              final next = store.nextUp();
              final recent = store.recent();
              final q = store.queueItems;
              Shelf shelf(String t, List<Item> l) => Shelf(t, [for (final i in l) itemTile(context, i)],
                  selected: sel, onSelect: _toggle);
              return ListView(padding: const EdgeInsets.only(bottom: 16), children: [
                if (cont.isNotEmpty) shelf('Continue watching', cont),
                if (next.isNotEmpty) shelf('Next up', next),
                if (q.isNotEmpty) shelf('Queue', q),
                if (recent.isNotEmpty) shelf('Recently added', recent),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const AllVideosPage())),
                    icon: const Icon(Icons.video_library_outlined),
                    label: Text('All videos (${store.visible.length})'),
                  ),
                ),
                if (!selecting)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Text('Tip: long-press a video to select several.',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
              ]);
            }),
          ),
        );
      },
    );
  }
}

/// Every video in one place: search, sort, select many, act on them.
class AllVideosPage extends StatefulWidget {
  const AllVideosPage({super.key});
  @override
  State<AllVideosPage> createState() => _AllVideosPageState();
}

class _AllVideosPageState extends State<AllVideosPage> {
  final sel = <String>{};
  String q = '';
  bool searching = false;
  int sort = 0; // 0 name, 1 recently added, 2 recently watched, 3 size

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final words = q.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
        final list = store.visible.where((i) {
          if (words.isEmpty) return true;
          final t = '${i.name} ${i.detail} ${p.basename(i.path)}'.toLowerCase();
          return words.every(t.contains);
        }).toList();
        list.sort((a, b) {
          switch (sort) {
            case 1:
              return b.added.compareTo(a.added);
            case 2:
              return store.lastPlayed(b.path).compareTo(store.lastPlayed(a.path));
            case 3:
              return b.size.compareTo(a.size);
            default:
              final c = naturalCompare(a.name, b.name);
              if (c != 0) return c;
              return (a.isEpisode && b.isEpisode) ? Store.compareEpisodes(a, b) : naturalCompare(a.path, b.path);
          }
        });
        sel.removeWhere((x) => !store.byPath.containsKey(x));
        final selecting = sel.isNotEmpty;
        final tiles = [for (final i in list) itemTile(context, i, subtitle: i.isEpisode ? i.detail : fmtSize(i.size))];
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (_, __) {
            if (selecting) setState(sel.clear);
          },
          child: Scaffold(
            appBar: selecting
                ? selectionBar(context, sel,
                    clear: () => setState(sel.clear),
                    selectAll: () => setState(() => sel.addAll(list.map((i) => i.path))))
                : AppBar(
                    title: searching
                        ? TextField(
                            autofocus: true,
                            decoration: const InputDecoration(hintText: 'Search files', border: InputBorder.none),
                            onChanged: (v) => setState(() => q = v.trim()),
                          )
                        : Text('All videos (${list.length})'),
                    actions: [
                      IconButton(
                        icon: Icon(searching ? Icons.close : Icons.search),
                        onPressed: () => setState(() {
                          searching = !searching;
                          if (!searching) q = '';
                        }),
                      ),
                      PopupMenuButton<int>(
                        icon: const Icon(Icons.sort),
                        onSelected: (v) => setState(() => sort = v),
                        itemBuilder: (_) => [
                          for (final e in {0: 'Name', 1: 'Recently added', 2: 'Recently watched', 3: 'Size'}.entries)
                            CheckedPopupMenuItem(value: e.key, checked: sort == e.key, child: Text(e.value)),
                        ],
                      ),
                      const LayoutButton(),
                    ],
                  ),
            body: tiles.isEmpty
                ? const EmptyState(Icons.video_library_outlined, 'No videos.')
                : TilesView(
                    tiles: tiles,
                    selected: sel,
                    onSelect: (id) => setState(() => sel.contains(id) ? sel.remove(id) : sel.add(id)),
                  ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- Search

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final words = q.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
    bool hit(String s) {
      final l = s.toLowerCase();
      return words.every(l.contains);
    }

    final shows = <MapEntry<String, List<Item>>>[];
    final movies = <Item>[];
    final eps = <Item>[];
    if (words.isNotEmpty) {
      store.shows.forEach((k, v) {
        if (hit(v.first.show!)) shows.add(MapEntry(k, v));
      });
      for (final i in store.visible) {
        if (i.isEpisode) {
          if (hit('${i.show} ${i.epLabel} ${i.sub ?? ''} ${p.basename(i.path)}') &&
              !hit(i.show!)) {
            eps.add(i);
          }
        } else if (hit('${i.name} ${p.basename(i.path)}')) {
          movies.add(i);
        }
      }
    }
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white70)),
        );
    Widget row(TileData t) => InkWell(
          onTap: t.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              SizedBox(
                width: 120,
                child: ArtThumb(item: t.art, artPath: t.artPath, watch: t.watch, fraction: t.fraction),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (t.subtitle != null)
                    Text(t.subtitle!, style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ]),
              ),
            ]),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search movies, shows, episodes',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => q = v.trim()),
        ),
      ),
      body: words.isEmpty
          ? const EmptyState(Icons.search, 'Type to search your library.')
          : (shows.isEmpty && movies.isEmpty && eps.isEmpty)
              ? const EmptyState(Icons.search_off, 'Nothing found.')
              : ListView(children: [
                  if (shows.isNotEmpty) head('Shows'),
                  for (final s in shows)
                    row(showTile(context, s.key, s.value)),
                  if (movies.isNotEmpty) head('Movies'),
                  for (final m in movies) row(itemTile(context, m)),
                  if (eps.isNotEmpty) head('Episodes'),
                  for (final e in eps.take(100))
                    row(itemTile(context, e, subtitle: '${e.show} · ${e.detail}')),
                ]),
    );
  }
}

TileData showTile(BuildContext context, String key, List<Item> eps) {
  final (w, f) = showWatch(eps);
  final seasons = eps.map((e) => e.season).toSet().length;
  final left = eps.where((e) => store.prog(e.path)?.watched != true).length;
  return TileData(
    id: key,
    title: eps.first.show!,
    subtitle: left > 0 && left < eps.length
        ? '$left of ${eps.length} left'
        : '${eps.length} episode${eps.length == 1 ? '' : 's'} · $seasons season${seasons == 1 ? '' : 's'}',
    art: eps.first,
    artPath: showArt(eps),
    watch: w,
    fraction: f,
    onTap: () => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShowPage(name: eps.first.show!, keyName: key),
    )),
  );
}

// ------------------------------------------------------- Movies / Shows

class LibraryPage extends StatefulWidget {
  final bool shows;
  const LibraryPage({super.key, required this.shows});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String q = '';
  bool searching = false, unwatchedOnly = false;
  final sel = <String>{};

  int get sort => widget.shows ? store.showSort : store.movieSort;

  List<TileData> _tiles(BuildContext context) {
    final out = <(TileData, Item, int, int, int, int)>[];
    // (tile, sample, added, watched, year, size)
    if (!widget.shows) {
      for (final i in store.movies) {
        if (unwatchedOnly && store.prog(i.path)?.watched == true) continue;
        out.add((itemTile(context, i), i, i.added, store.lastPlayed(i.path), i.year ?? 0, i.size));
      }
    } else {
      store.shows.forEach((key, eps) {
        if (unwatchedOnly && eps.every((e) => store.prog(e.path)?.watched == true)) return;
        var added = 0, played = 0, size = 0;
        for (final e in eps) {
          if (e.added > added) added = e.added;
          final l = store.lastPlayed(e.path);
          if (l > played) played = l;
          size += e.size;
        }
        out.add((showTile(context, key, eps), eps.first, added, played, 0, size));
      });
    }
    final filtered = q.isEmpty
        ? out
        : out.where((t) => t.$1.title.toLowerCase().contains(q)).toList();
    filtered.sort((a, b) {
      int byTitle() => naturalCompare(a.$1.title, b.$1.title);
      switch (sort) {
        case 1:
          return b.$3.compareTo(a.$3);
        case 2:
          final c = b.$4.compareTo(a.$4);
          return c != 0 ? c : byTitle();
        case 3:
          final c = b.$5.compareTo(a.$5);
          return c != 0 ? c : byTitle();
        case 4:
          return b.$6.compareTo(a.$6);
        default:
          return byTitle();
      }
    });
    return [for (final t in filtered) t.$1];
  }

  List<String> _selPaths() {
    if (!widget.shows) return sel.toList();
    return [
      for (final k in sel) ...?store.shows[k]?.map((e) => e.path),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final tiles = _tiles(context);
        sel.removeWhere((id) => !tiles.any((t) => t.id == id));
        final selecting = sel.isNotEmpty;
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (_, __) {
            if (selecting) setState(sel.clear);
          },
          child: Scaffold(
            appBar: selecting
                ? AppBar(
                    leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(sel.clear)),
                    title: Text('${sel.length} selected'),
                    actions: [
                      IconButton(
                        tooltip: 'Select all',
                        icon: const Icon(Icons.select_all),
                        onPressed: () => setState(() => sel.addAll(tiles.map((t) => t.id))),
                      ),
                      IconButton(
                        tooltip: 'Add to folder',
                        icon: const Icon(Icons.drive_file_move_outline),
                        onPressed: () async {
                          final id = await pickCollection(context);
                          if (id != null) {
                            store.addToColl(id, _selPaths());
                            setState(sel.clear);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Watched / unwatched',
                        icon: const Icon(Icons.check_circle_outline),
                        onPressed: () {
                          final ps = _selPaths();
                          final allDone = ps.every((x) => store.prog(x)?.watched == true);
                          store.markMany(ps, !allDone);
                          setState(sel.clear);
                        },
                      ),
                      IconButton(
                        tooltip: 'More',
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => bulkSheet(context, _selPaths(), done: () => setState(sel.clear)),
                      ),
                    ],
                  )
                : AppBar(
                    title: searching
                        ? TextField(
                            autofocus: true,
                            decoration: const InputDecoration(hintText: 'Search', border: InputBorder.none),
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
                      PopupMenuButton<int>(
                        tooltip: 'Sort and filter',
                        icon: const Icon(Icons.sort),
                        onSelected: (v) {
                          if (v == 99) {
                            setState(() => unwatchedOnly = !unwatchedOnly);
                          } else {
                            store.update(() {
                              if (widget.shows) {
                                store.showSort = v;
                              } else {
                                store.movieSort = v;
                              }
                            });
                          }
                        },
                        itemBuilder: (_) => [
                          for (var i = 0; i < Store.sortNames.length; i++)
                            if (!(widget.shows && i == 3))
                              CheckedPopupMenuItem(value: i, checked: sort == i, child: Text(Store.sortNames[i])),
                          const PopupMenuDivider(),
                          CheckedPopupMenuItem(value: 99, checked: unwatchedOnly, child: const Text('Unwatched only')),
                        ],
                      ),
                      const LayoutButton(),
                      rescanButton(),
                    ],
                  ),
            body: tiles.isEmpty
                ? EmptyState(
                    widget.shows ? Icons.tv_outlined : Icons.movie_outlined,
                    store.items.isEmpty ? 'Add videos in the Sources tab.' : 'Nothing matches.',
                  )
                : TilesView(
                    tiles: tiles,
                    selected: sel,
                    onSelect: (id) => setState(() => sel.contains(id) ? sel.remove(id) : sel.add(id)),
                  ),
          ),
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
        final rp = eps.isEmpty ? null : store.prog(eps[ri].path);
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.name),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'sw':
                      store.markMany(list.map((e) => e.path), true);
                    case 'su':
                      store.markMany(list.map((e) => e.path), false);
                    case 'aw':
                      store.markMany(eps.map((e) => e.path), true);
                    case 'au':
                      store.markMany(eps.map((e) => e.path), false);
                    case 'f':
                      final id = await pickCollection(context);
                      if (id != null) store.addToColl(id, eps.map((e) => e.path));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'sw', child: Text('Mark season watched')),
                  PopupMenuItem(value: 'su', child: Text('Mark season unwatched')),
                  PopupMenuItem(value: 'aw', child: Text('Mark all watched')),
                  PopupMenuItem(value: 'au', child: Text('Mark all unwatched')),
                  PopupMenuItem(value: 'f', child: Text('Add show to folder')),
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
                            '${rp != null && !rp.watched && rp.pos > 15000 ? 'Resume' : 'Play'} ${eps[ri].epLabel}'),
                      ),
                    ]),
                  ),
                  if (seasons.length > 1)
                    SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        children: [
                          for (final s in seasons)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(s == 0 ? 'Specials' : 'Season $s'),
                                selected: s == sel,
                                onSelected: (_) => setState(() => season = s),
                              ),
                            ),
                        ],
                      ),
                    ),
                  for (final e in list) _episode(context, e, eps),
                ]),
        );
      },
    );
  }

  Widget _episode(BuildContext context, Item e, List<Item> all) {
    final pr = store.prog(e.path);
    final (w, f) = itemWatch(e);
    final status = w == Watch.done
        ? 'Watched'
        : w == Watch.partial
            ? '${fmt(Duration(milliseconds: pr!.pos))} / ${fmt(Duration(milliseconds: pr.dur))}'
            : fmtSize(e.size);
    return InkWell(
      onTap: () => playItems(context, all, all.indexOf(e)),
      onLongPress: () => itemSheet(context, e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          SizedBox(width: 140, child: ArtThumb(item: e, watch: w, fraction: f)),
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
              Text(status, style: const TextStyle(fontSize: 12, color: Colors.white54)),
            ]),
          ),
          IconButton(
            icon: Icon(
              pr?.watched == true ? Icons.check_circle : Icons.radio_button_unchecked,
              color: pr?.watched == true ? null : Colors.white38,
            ),
            onPressed: () => store.markWatched(e.path, pr?.watched != true),
          ),
        ]),
      ),
    );
  }
}
