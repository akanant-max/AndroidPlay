import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'folderview.dart';
import 'models.dart';
import 'pages.dart';
import 'store.dart';
import 'widgets.dart';

/// Virtual folders. Only paths are stored, so nothing is copied.
class CollectionPage extends StatefulWidget {
  final String? id;
  const CollectionPage({super.key, required this.id});
  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  final sel = <String>{};
  int sort = 0; // 0 name, 1 order added, 2 recently added file, 3 recently watched

  Coll? get me => store.coll(widget.id);

  List<Item> _items() {
    final c = me;
    if (c == null) return [];
    final list = [for (final x in c.items) if (store.byPath[x] != null) store.byPath[x]!];
    switch (sort) {
      case 0:
        list.sort((a, b) {
          if (a.isEpisode && b.isEpisode && showKey(a.show!) == showKey(b.show!)) {
            return Store.compareEpisodes(a, b);
          }
          return naturalCompare(a.name, b.name);
        });
      case 2:
        list.sort((a, b) => b.added.compareTo(a.added));
      case 3:
        list.sort((a, b) => store.lastPlayed(b.path).compareTo(store.lastPlayed(a.path)));
      default:
        break;
    }
    return list;
  }

  Future<void> _folderMenu(Coll k) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(k.name)),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'r')),
          ListTile(leading: const Icon(Icons.drive_file_move_outline), title: const Text('Move into another folder'), onTap: () => Navigator.pop(ctx, 'm')),
          if (k.parent != null)
            ListTile(leading: const Icon(Icons.vertical_align_top), title: const Text('Move to top level'), onTap: () => Navigator.pop(ctx, 't')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete folder'), subtitle: const Text('Videos stay in your library'), onTap: () => Navigator.pop(ctx, 'd')),
        ]),
      ),
    );
    if (!mounted) return;
    switch (v) {
      case 'r':
        final n = await askName(context, 'Rename folder', initial: k.name);
        if (n != null) store.renameColl(k.id, n);
      case 'm':
        final to = await pickCollection(context, title: 'Move into', exclude: k.id);
        if (to != null) store.moveColl(k.id, to);
      case 't':
        store.moveColl(k.id, null);
      case 'd':
        store.deleteColl(k.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final isRoot = widget.id == null;
        final c = me;
        if (!isRoot && c == null) {
          return Scaffold(appBar: AppBar(), body: const EmptyState(Icons.folder_off_outlined, 'This folder was deleted.'));
        }
        final kids = store.childrenOf(widget.id);
        final items = _items();
        sel.removeWhere((x) => !items.any((i) => i.path == x));
        final selecting = sel.isNotEmpty;
        final tiles = <TileData>[
          for (final k in kids)
            TileData(
              id: 'coll:${k.id}',
              title: k.name,
              subtitle: '${store.collCount(k.id)} videos',
              icon: Icons.folder,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionPage(id: k.id))),
            ),
          for (final i in items)
            itemTile(context, i, subtitle: i.isEpisode ? i.detail : null),
        ];
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
                        icon: const Icon(Icons.select_all),
                        onPressed: () => setState(() => sel.addAll(items.map((i) => i.path))),
                      ),
                      IconButton(
                        tooltip: 'Remove from folder',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () {
                          store.removeFromColl(widget.id!, sel);
                          setState(sel.clear);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => bulkSheet(context, sel.toList(), inColl: widget.id, done: () => setState(sel.clear)),
                      ),
                    ],
                  )
                : AppBar(
                    title: Text(isRoot ? 'My folders' : c!.name),
                    actions: [
                      if (items.isNotEmpty)
                        IconButton(
                          tooltip: 'Play all',
                          icon: const Icon(Icons.playlist_play),
                          onPressed: () => playItems(context, items, 0),
                        ),
                      if (!isRoot)
                        PopupMenuButton<int>(
                          icon: const Icon(Icons.sort),
                          onSelected: (v) => setState(() => sort = v),
                          itemBuilder: (_) => [
                            for (final e in {0: 'Name', 1: 'Order added', 2: 'Recently added', 3: 'Recently watched'}.entries)
                              CheckedPopupMenuItem(value: e.key, checked: sort == e.key, child: Text(e.value)),
                          ],
                        ),
                      const LayoutButton(),
                      if (!isRoot)
                        IconButton(
                          tooltip: 'Folder options',
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => _folderMenu(c!),
                        ),
                    ],
                  ),
            floatingActionButton: selecting
                ? null
                : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (!isRoot)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: FloatingActionButton.extended(
                          heroTag: 'add-${widget.id}',
                          onPressed: () async {
                            final picked = await Navigator.of(context).push<List<String>>(
                              MaterialPageRoute(builder: (_) => PickVideosPage(already: c!.items.toSet())),
                            );
                            if (picked != null && picked.isNotEmpty) store.addToColl(c!.id, picked);
                          },
                          icon: const Icon(Icons.playlist_add),
                          label: const Text('Add videos'),
                        ),
                      ),
                    FloatingActionButton(
                      heroTag: 'new-${widget.id}',
                      tooltip: 'New folder',
                      onPressed: () async {
                        final n = await askName(context, 'New folder');
                        if (n != null) store.createColl(n, parent: widget.id);
                      },
                      child: const Icon(Icons.create_new_folder_outlined),
                    ),
                  ]),
            body: tiles.isEmpty
                ? EmptyState(
                    Icons.folder_special_outlined,
                    isRoot
                        ? 'Make your own folders to organise videos any way you like. '
                            'They only hold links, so they take no extra space.'
                        : 'Empty folder. Add videos or make a subfolder.',
                  )
                : TilesView(
                    tiles: tiles,
                    selected: sel,
                    onSelect: (id) {
                      if (id == 'queue' || id == 'all' || id == 'disk') return;
                      if (id.startsWith('coll:')) {
                        final k = store.coll(id.substring(5));
                        if (k != null && sel.isEmpty) _folderMenu(k);
                        return;
                      }
                      setState(() => sel.contains(id) ? sel.remove(id) : sel.add(id));
                    },
                  ),
          ),
        );
      },
    );
  }
}

/// Multi-select any videos from the library. Returns their paths.
class PickVideosPage extends StatefulWidget {
  final Set<String> already;
  const PickVideosPage({super.key, this.already = const {}});
  @override
  State<PickVideosPage> createState() => _PickVideosPageState();
}

class _PickVideosPageState extends State<PickVideosPage> {
  final sel = <String>{};
  String q = '';

  @override
  Widget build(BuildContext context) {
    final words = q.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
    final list = store.visible.where((i) {
      if (words.isEmpty) return true;
      final s = '${i.name} ${i.detail} ${p.basename(i.path)}'.toLowerCase();
      return words.every(s.contains);
    }).toList()
      ..sort((a, b) {
        final c = naturalCompare(a.name, b.name);
        if (c != 0) return c;
        if (a.isEpisode && b.isEpisode) return Store.compareEpisodes(a, b);
        return 0;
      });
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(hintText: 'Search videos', border: InputBorder.none),
          onChanged: (v) => setState(() => q = v.trim()),
        ),
        actions: [
          IconButton(
            tooltip: 'Select all shown',
            icon: const Icon(Icons.select_all),
            onPressed: () => setState(() => sel.addAll(list.map((i) => i.path))),
          ),
        ],
      ),
      floatingActionButton: sel.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.pop(context, sel.toList()),
              icon: const Icon(Icons.check),
              label: Text('Add ${sel.length}'),
            ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: list.length,
        itemBuilder: (_, i) {
          final it = list[i];
          final inAlready = widget.already.contains(it.path);
          return CheckboxListTile(
            value: inAlready || sel.contains(it.path),
            onChanged: inAlready
                ? null
                : (v) => setState(() => v == true ? sel.add(it.path) : sel.remove(it.path)),
            secondary: SizedBox(width: 96, child: ArtThumb(item: it, watch: itemWatch(it).$1, fraction: itemWatch(it).$2)),
            title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(it.isEpisode ? it.detail : p.basename(it.path), maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    );
  }
}


/// The user's own play queue: reorder, remove, play from any point.
class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = store.queueItems;
        var total = 0;
        for (final i in items) {
          total += store.durOf(i.path) ?? 0;
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Queue'),
            actions: [
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Play all',
                  icon: const Icon(Icons.playlist_play),
                  onPressed: () => playItems(context, items, 0),
                ),
              if (items.isNotEmpty)
                IconButton(
                  tooltip: 'Clear queue',
                  icon: const Icon(Icons.clear_all),
                  onPressed: store.clearQueue,
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () async {
              final picked = await Navigator.of(context).push<List<String>>(
                MaterialPageRoute(builder: (_) => PickVideosPage(already: store.queue.toSet())),
              );
              if (picked != null && picked.isNotEmpty) store.addToQueue(picked);
            },
            icon: const Icon(Icons.playlist_add),
            label: const Text('Add videos'),
          ),
          body: items.isEmpty
              ? const EmptyState(
                  Icons.queue_play_next,
                  'Your queue is empty. Add videos here, or use "Add to queue" from any video\'s options.',
                )
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(children: [
                      Text('${items.length} videos${total > 0 ? ' · ${fmt(Duration(milliseconds: total))}' : ''}',
                          style: const TextStyle(color: Colors.white60)),
                      const Spacer(),
                      const Text('Drag to reorder', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ]),
                  ),
                  Expanded(
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: items.length,
                      onReorder: (a, b) => store.moveInQueue(a, b > a ? b - 1 : b),
                      itemBuilder: (_, i) {
                        final it = items[i];
                        final (w, f) = itemWatch(it);
                        final d = store.durOf(it.path);
                        return ListTile(
                          key: ValueKey(it.path),
                          onTap: () => playItems(context, items, i),
                          leading: SizedBox(width: 96, child: ArtThumb(item: it, watch: w, fraction: f)),
                          title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [if (it.isEpisode) it.detail, if (d != null) fmt(Duration(milliseconds: d))].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close),
                            onPressed: () => store.removeFromQueue([it.path]),
                          ),
                        );
                      },
                    ),
                  ),
                ]),
        );
      },
    );
  }
}
