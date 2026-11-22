import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'player.dart';
import 'store.dart';
import 'thumbs.dart';
import 'widgets.dart';

const internalRoot = '/storage/emulated/0';

Future<void> openBrowser(BuildContext c) async {
  if (!await ensureStorage()) {
    if (c.mounted) {
      ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
        content: Text('Allow "All files access" so AURA can see your videos'),
      ));
    }
    return;
  }
  if (c.mounted) {
    await Navigator.of(c).push(MaterialPageRoute(builder: (_) => const BrowserPage()));
  }
}

class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key});

  static const _quick = [
    '$internalRoot/Movies',
    '$internalRoot/Download',
    '$internalRoot/DCIM',
    '$internalRoot/Videos',
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
          appBar: AppBar(title: const Text('Sources')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => openBrowser(context),
            icon: const Icon(Icons.add),
            label: const Text('Add folder or files'),
          ),
          body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: Text('${store.items.length} videos · ${store.movies.length} movies · ${store.shows.length} shows'),
              subtitle: Text(store.scanning
                  ? 'Scanning…'
                  : thumbs.pending > 0
                      ? 'Making thumbnails: ${thumbs.pending} left'
                      : 'Up to date'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.tonalIcon(
                onPressed: store.scanning ? null : () => store.rescan(ask: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Scan for changes'),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'AURA only links to your files. Nothing is copied and nothing goes online.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            _head(context, 'Folders'),
            if (store.folders.isEmpty)
              const ListTile(dense: true, title: Text('No folders yet', style: TextStyle(color: Colors.white54))),
            for (final f in store.folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(p.basename(f).isEmpty ? f : p.basename(f)),
                subtitle: Text(
                  '${f.replaceFirst(internalRoot, 'Phone')}\n'
                  '${store.items.where((i) => p.isWithin(f, i.path)).length} videos'
                  '${Directory(f).existsSync() ? '' : ' · not found'}',
                ),
                isThreeLine: true,
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => store.removeFolder(f),
                ),
              ),
            if (quick.isNotEmpty)
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
            _head(context, 'Single files'),
            if (store.files.isEmpty)
              const ListTile(dense: true, title: Text('No single files', style: TextStyle(color: Colors.white54))),
            for (final f in store.files)
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: Text(p.basename(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(p.dirname(f).replaceFirst(internalRoot, 'Phone'),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => store.removeFile(f),
                ),
              ),
            if (store.hidden.isNotEmpty) ...[
              _head(context, 'Hidden'),
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: Text('Unhide ${store.hidden.length} hidden videos'),
                onTap: store.unhideAll,
              ),
            ],
          ]),
        );
      },
    );
  }

  Widget _head(BuildContext c, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t,
            style: TextStyle(color: Theme.of(c).colorScheme.primary, fontWeight: FontWeight.w700)),
      );
}

enum BrowseMode { library, subtitle }

/// In-app file browser: links files and folders without copying them.
class BrowserPage extends StatefulWidget {
  final BrowseMode mode;
  final String? start;
  const BrowserPage({super.key, this.mode = BrowseMode.library, this.start});
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  String? dir; // null = list of storage roots
  final sel = <String>{};
  List<FileSystemEntity> entries = [];
  String? error;

  bool get _subs => widget.mode == BrowseMode.subtitle;

  @override
  void initState() {
    super.initState();
    final s = widget.start;
    _go(s != null && Directory(s).existsSync() ? s : internalRoot);
  }

  List<String> _roots() {
    final out = <String>[internalRoot];
    try {
      for (final e in Directory('/storage').listSync()) {
        final n = p.basename(e.path);
        if (e is Directory && n != 'emulated' && n != 'self') out.add(e.path);
      }
    } catch (_) {}
    return out;
  }

  void _go(String? d) {
    setState(() {
      dir = d;
      error = null;
      entries = [];
      if (d == null) return;
      try {
        final all = Directory(d).listSync(followLinks: false);
        final dirs = all.whereType<Directory>().where((x) => !p.basename(x.path).startsWith('.')).toList()
          ..sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
        final fs = all.whereType<File>().where((x) {
          final ext = p.extension(x.path).toLowerCase().replaceFirst('.', '');
          return _subs ? subExts.contains(ext) : videoExts.contains(ext);
        }).toList()
          ..sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
        entries = [...dirs, ...fs];
      } catch (e) {
        error = 'Cannot open this folder';
      }
    });
  }

  bool _up() {
    final d = dir;
    if (d == null) return false;
    final roots = _roots();
    if (roots.contains(d)) {
      _go(null);
    } else {
      _go(p.dirname(d));
    }
    return true;
  }

  String _label(String d) => d == internalRoot
      ? 'Phone storage'
      : d.startsWith('$internalRoot/')
          ? 'Phone / ${d.substring(internalRoot.length + 1)}'
          : d;

  @override
  Widget build(BuildContext context) {
    final d = dir;
    final inLibrary = d != null && store.folders.any((f) => f == d || p.isWithin(f, d));
    return PopScope(
      canPop: d == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_subs ? 'Pick subtitle file' : (d == null ? 'Storage' : _label(d)),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (!_subs && sel.isNotEmpty)
              IconButton(icon: const Icon(Icons.close), onPressed: () => setState(sel.clear)),
          ],
        ),
        bottomNavigationBar: _subs || d == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: inLibrary
                            ? null
                            : () async {
                                Navigator.pop(context);
                                await store.addFolder(d);
                              },
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(inLibrary ? 'Folder added' : 'Add this folder'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: sel.isEmpty
                            ? null
                            : () async {
                                final picked = sel.toList();
                                Navigator.pop(context);
                                await store.addFiles(picked);
                              },
                        icon: const Icon(Icons.playlist_add),
                        label: Text(sel.isEmpty ? 'Add files' : 'Add ${sel.length} files'),
                      ),
                    ),
                  ]),
                ),
              ),
        body: d == null
            ? ListView(children: [
                for (final r in _roots())
                  ListTile(
                    leading: Icon(r == internalRoot ? Icons.smartphone : Icons.sd_card_outlined),
                    title: Text(r == internalRoot ? 'Phone storage' : 'SD card / USB (${p.basename(r)})'),
                    onTap: () => _go(r),
                  ),
              ])
            : error != null
                ? EmptyState(Icons.folder_off_outlined, error!)
                : ListView.builder(
                    itemCount: entries.length + 1,
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return ListTile(
                          leading: const Icon(Icons.arrow_upward),
                          title: const Text('Up'),
                          onTap: _up,
                        );
                      }
                      final e = entries[i - 1];
                      final name = p.basename(e.path);
                      if (e is Directory) {
                        return ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(name),
                          onTap: () => _go(e.path),
                        );
                      }
                      if (_subs) {
                        return ListTile(
                          leading: const Icon(Icons.subtitles_outlined),
                          title: Text(name),
                          onTap: () => Navigator.pop(context, e.path),
                        );
                      }
                      final known = store.byPath.containsKey(e.path);
                      int size = 0;
                      try {
                        size = (e as File).lengthSync();
                      } catch (_) {}
                      return ListTile(
                        leading: Checkbox(
                          value: known || sel.contains(e.path),
                          onChanged: known
                              ? null
                              : (v) => setState(() => v == true ? sel.add(e.path) : sel.remove(e.path)),
                        ),
                        title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(known ? 'In library · ${fmtSize(size)}' : fmtSize(size)),
                        trailing: IconButton(
                          tooltip: 'Play',
                          icon: const Icon(Icons.play_circle_outline),
                          onPressed: () {
                            final (q, idx) = store.queueForPath(e.path);
                            Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                              builder: (_) => PlayerPage(queue: q, index: idx),
                            ));
                          },
                        ),
                        onTap: known
                            ? null
                            : () => setState(() => sel.contains(e.path) ? sel.remove(e.path) : sel.add(e.path)),
                      );
                    },
                  ),
      ),
    );
  }
}
