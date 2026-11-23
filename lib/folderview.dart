import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'collections.dart';
import 'models.dart';
import 'pages.dart';
import 'platform.dart';
import 'store.dart';
import 'thumbs.dart';
import 'widgets.dart';

/// Your library as it sits on disk: folders stay folders.
/// [path] null = the list of source folders.
class FolderViewPage extends StatefulWidget {
  final String? path;
  const FolderViewPage({super.key, this.path});
  @override
  State<FolderViewPage> createState() => _FolderViewPageState();
}

class _FolderViewPageState extends State<FolderViewPage> {
  final sel = <String>{};
  int sort = 0; // 0 name, 1 recently added

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final isHome = widget.path == null;
        // only one folder added and no single files: open it straight away
        final root = widget.path ??
            (store.folders.length == 1 && store.files.isEmpty ? store.folders.first : null);
        final dirs = <String, List<Item>>{}; // child folder -> videos under it
        final files = <Item>[];
        if (root == null) {
          for (final f in store.folders) {
            dirs[f] = store.visible.where((i) => p.isWithin(f, i.path)).toList();
          }
          final singles = store.visible.where((i) => store.files.contains(i.path)).toList();
          files.addAll(singles);
        } else {
          for (final i in store.visible) {
            if (!p.isWithin(root, i.path)) continue;
            final parts = p.split(p.relative(i.path, from: root));
            if (parts.length == 1) {
              files.add(i);
            } else {
              dirs.putIfAbsent(p.join(root, parts.first), () => []).add(i);
            }
          }
        }
        final dirKeys = dirs.keys.toList();
        if (sort == 1) {
          int newest(String d) => dirs[d]!.fold(0, (a, b) => b.added > a ? b.added : a);
          dirKeys.sort((a, b) => newest(b).compareTo(newest(a)));
          files.sort((a, b) => b.added.compareTo(a.added));
        } else {
          dirKeys.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
          files.sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
        }
        sel.removeWhere((x) => !files.any((i) => i.path == x));
        final selecting = sel.isNotEmpty;

        final tiles = <TileData>[
          if (isHome) ...[
            TileData(
              id: 'x:queue',
              title: 'Queue',
              subtitle: '${store.queueItems.length} videos · your playlist',
              icon: Icons.queue_play_next,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QueuePage())),
            ),
            TileData(
              id: 'x:mine',
              title: 'My folders',
              subtitle: '${store.childrenOf(null).length} custom folders',
              icon: Icons.folder_special_outlined,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const CollectionPage(id: null))),
            ),
            TileData(
              id: 'x:all',
              title: 'All videos',
              subtitle: '${store.visible.length} videos',
              icon: Icons.video_library_outlined,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AllVideosPage())),
            ),
          ],
          for (final d in dirKeys)
            TileData(
              id: 'dir:$d',
              title: p.basename(d).isEmpty ? d : p.basename(d),
              subtitle: '${dirs[d]!.length} video${dirs[d]!.length == 1 ? '' : 's'}',
              artPath: dirs[d]!.isEmpty ? null : thumbs.artFor(dirs[d]!.first),
              icon: dirs[d]!.isEmpty || thumbs.artFor(dirs[d]!.first) == null ? Icons.folder_outlined : null,
              watch: dirs[d]!.isEmpty ? Watch.done : showWatch(dirs[d]!).$1,
              fraction: dirs[d]!.isEmpty ? 0 : showWatch(dirs[d]!).$2,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => FolderViewPage(path: d))),
            ),
          for (final i in files)
            itemTile(context, i,
                subtitle: p.basename(i.path),
                onTap: () => playItems(context, files, files.indexOf(i))),
        ];

        final title = isHome ? 'Folders' : (p.basename(root!).isEmpty ? root : p.basename(root));
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (_, __) {
            if (selecting) setState(sel.clear);
          },
          child: Scaffold(
            appBar: selecting
                ? selectionBar(context, sel,
                    clear: () => setState(sel.clear),
                    selectAll: () => setState(() => sel.addAll(files.map((i) => i.path))))
                : AppBar(
                    title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title),
                      if (root != null)
                        Text(prettyPath(root),
                            style: const TextStyle(fontSize: 12, color: Colors.white54),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ]),
                    actions: [
                      if (files.isNotEmpty)
                        IconButton(
                          tooltip: 'Play all in this folder',
                          icon: const Icon(Icons.playlist_play),
                          onPressed: () => playItems(context, files, 0),
                        ),
                      PopupMenuButton<int>(
                        icon: const Icon(Icons.sort),
                        onSelected: (v) => setState(() => sort = v),
                        itemBuilder: (_) => [
                          CheckedPopupMenuItem(value: 0, checked: sort == 0, child: const Text('Name')),
                          CheckedPopupMenuItem(value: 1, checked: sort == 1, child: const Text('Recently added')),
                        ],
                      ),
                      const LayoutButton(),
                    ],
                  ),
            body: store.items.isEmpty && isHome
                ? const EmptyState(Icons.folder_open, 'Add a folder in the Sources tab and it shows up here, organised the way it is on disk.')
                : tiles.isEmpty
                ? const EmptyState(Icons.folder_open, 'No videos here.')
                : TilesView(
                    tiles: tiles,
                    selected: sel,
                    onSelect: (id) {
                      if (id.startsWith('dir:') || id.startsWith('x:')) return;
                      setState(() => sel.contains(id) ? sel.remove(id) : sel.add(id));
                    },
                  ),
          ),
        );
      },
    );
  }
}
