import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'player.dart';
import 'store.dart';
import 'thumbs.dart';

String fmtSize(int b) {
  if (b <= 0) return '';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i >= 3 ? 1 : 0)} ${u[i]}';
}

Future<void> playItems(BuildContext c, List<Item> q, int i, {bool fromStart = false}) =>
    Navigator.of(c, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => PlayerPage(queue: q, index: i, fromStart: fromStart)),
    );

Future<void> playItem(BuildContext c, Item it, {bool fromStart = false}) {
  final (q, i) = store.queueFor(it);
  return playItems(c, q, i, fromStart: fromStart);
}

// ------------------------------------------------------------ watch state

enum Watch { fresh, partial, done }

/// Watch state + bar fraction for a single video.
(Watch, double) itemWatch(Item i) {
  final pr = store.prog(i.path);
  if (pr == null) return (Watch.fresh, 0);
  if (pr.watched) return (Watch.done, 1);
  if (pr.pos > 15000) return (Watch.partial, pr.frac);
  return (Watch.fresh, 0);
}

/// Watch state for a show: bar = share of episodes watched.
(Watch, double) showWatch(List<Item> eps) {
  final w = eps.where((e) => store.prog(e.path)?.watched == true).length;
  final started = eps.any((e) => (store.prog(e.path)?.pos ?? 0) > 15000);
  if (w == eps.length) return (Watch.done, 1);
  if (w == 0 && !started) return (Watch.fresh, 0);
  return (Watch.partial, w / eps.length);
}

class _CornerPainter extends CustomPainter {
  final Color color;
  _CornerPainter(this.color);
  @override
  void paint(Canvas c, Size s) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(s.width, 0)
      ..lineTo(s.width, s.height)
      ..close();
    c.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CornerPainter o) => o.color != color;
}

/// 16:9 picture with Infuse-style watch marks.
class ArtThumb extends StatelessWidget {
  final Item? item;
  final String? artPath;
  final Watch watch;
  final double fraction;
  final IconData? icon;
  final bool selected;
  const ArtThumb({
    super.key,
    this.item,
    this.artPath,
    this.watch = Watch.done,
    this.fraction = 0,
    this.icon,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ListenableBuilder(
          listenable: thumbs,
          builder: (context, _) {
            final path = artPath ?? (item != null ? thumbs.artFor(item!) : null);
            final placeholder = Container(
              color: const Color(0xFF1A1A22),
              alignment: Alignment.center,
              child: Icon(icon ?? Icons.movie_outlined, color: Colors.white24, size: 34),
            );
            return Stack(fit: StackFit.expand, children: [
              if (path == null)
                placeholder
              else
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  cacheWidth: 500,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => placeholder,
                ),
              if (icon == null && watch == Watch.fresh)
                Positioned(
                  top: 0, right: 0,
                  child: CustomPaint(size: const Size(22, 22), painter: _CornerPainter(accent)),
                ),
              if (icon == null && watch == Watch.partial)
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.02, 1.0).toDouble(),
                    minHeight: 4,
                    color: accent,
                    backgroundColor: Colors.black54,
                  ),
                ),
              if (icon == null && watch == Watch.done)
                const Positioned(
                  top: 6, right: 6,
                  child: Icon(Icons.check_circle, color: Colors.white, size: 18, shadows: [
                    Shadow(blurRadius: 4, color: Colors.black),
                  ]),
                ),
              if (selected)
                Container(
                  color: accent.withOpacity(0.35),
                  alignment: Alignment.center,
                  child: const Icon(Icons.check_circle, color: Colors.white, size: 36),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ tiles

class TileData {
  final String id;
  final String title;
  final String? subtitle;
  final Item? art;
  final String? artPath;
  final Watch watch;
  final double fraction;
  final IconData? icon;
  final VoidCallback onTap;
  const TileData({
    required this.id,
    required this.title,
    this.subtitle,
    this.art,
    this.artPath,
    this.watch = Watch.done,
    this.fraction = 0,
    this.icon,
    required this.onTap,
  });
}

TileData itemTile(BuildContext c, Item i, {String? subtitle, VoidCallback? onTap}) {
  final (w, f) = itemWatch(i);
  return TileData(
    id: i.path,
    title: i.name,
    subtitle: subtitle ?? (i.detail.isEmpty ? null : i.detail),
    art: i,
    watch: w,
    fraction: f,
    onTap: onTap ?? () => playItem(c, i),
  );
}

class MediaCard extends StatelessWidget {
  final TileData t;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLong;
  const MediaCard(this.t, {super.key, this.selected = false, required this.onTap, required this.onLong});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLong,
      borderRadius: BorderRadius.circular(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ArtThumb(
          item: t.art, artPath: t.artPath, watch: t.watch, fraction: t.fraction,
          icon: t.icon, selected: selected,
        ),
        const SizedBox(height: 6),
        Text(t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (t.subtitle != null)
          Text(t.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ]),
    );
  }
}

/// Grid or list of tiles following the layout setting, with multi-select.
class TilesView extends StatelessWidget {
  final List<TileData> tiles;
  final Set<String> selected;
  final void Function(String id) onSelect;
  final EdgeInsets padding;
  const TilesView({
    super.key,
    required this.tiles,
    required this.selected,
    required this.onSelect,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 96),
  });

  @override
  Widget build(BuildContext context) {
    final selecting = selected.isNotEmpty;
    void tap(TileData t) => selecting ? onSelect(t.id) : t.onTap();
    if (store.layout == 'list') {
      return ListView.builder(
        padding: padding,
        itemCount: tiles.length,
        itemBuilder: (_, i) {
          final t = tiles[i];
          return InkWell(
            onTap: () => tap(t),
            onLongPress: () => onSelect(t.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(
                  width: 132,
                  child: ArtThumb(
                    item: t.art, artPath: t.artPath, watch: t.watch,
                    fraction: t.fraction, icon: t.icon, selected: selected.contains(t.id),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (t.subtitle != null)
                      Text(t.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
    }
    final ext = [150.0, 200.0, 280.0][store.gridSize.clamp(0, 2)];
    return LayoutBuilder(builder: (context, c) {
      final avail = c.maxWidth - padding.horizontal;
      final cols = (avail / ext).ceil().clamp(2, 8);
      final w = (avail - (cols - 1) * 12) / cols;
      return GridView.builder(
        padding: padding,
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
            t,
            selected: selected.contains(t.id),
            onTap: () => tap(t),
            onLong: () => onSelect(t.id),
          );
        },
      );
    });
  }
}

/// Layout picker button for app bars.
class LayoutButton extends StatelessWidget {
  const LayoutButton({super.key});
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Layout',
      icon: Icon(store.layout == 'list' ? Icons.view_list : Icons.grid_view),
      onSelected: (v) => store.update(() {
        if (v == 3) {
          store.layout = 'list';
        } else {
          store.layout = 'grid';
          store.gridSize = v;
        }
      }),
      itemBuilder: (_) => [
        for (final e in {0: 'Small grid', 1: 'Medium grid', 2: 'Large grid'}.entries)
          CheckedPopupMenuItem(
            value: e.key,
            checked: store.layout == 'grid' && store.gridSize == e.key,
            child: Text(e.value),
          ),
        CheckedPopupMenuItem(value: 3, checked: store.layout == 'list', child: const Text('List')),
      ],
    );
  }
}

class Shelf extends StatelessWidget {
  final String title;
  final List<TileData> tiles;
  const Shelf(this.title, this.tiles, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      SizedBox(
        height: 160,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: tiles.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (c, i) => SizedBox(
            width: 200,
            child: MediaCard(
              tiles[i],
              onTap: tiles[i].onTap,
              onLong: () {
                final it = tiles[i].art;
                if (it != null) itemSheet(c, it);
              },
            ),
          ),
        ),
      ),
    ]);
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const EmptyState(this.icon, this.text, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: Colors.white24),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

Future<String?> askName(BuildContext c, String title, {String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Pick a virtual folder (or make a new one). Returns its id.
Future<String?> pickCollection(BuildContext c, {String title = 'Add to folder', String? exclude}) {
  return showModalBottomSheet<String>(
    context: c,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final rows = <Widget>[];
      void walk(String? parent, int depth) {
        for (final k in store.childrenOf(parent)) {
          if (k.id == exclude) continue;
          rows.add(ListTile(
            contentPadding: EdgeInsets.only(left: 16.0 + depth * 20, right: 16),
            leading: const Icon(Icons.folder_outlined),
            title: Text(k.name),
            trailing: Text('${store.collCount(k.id)}'),
            onTap: () => Navigator.pop(ctx, k.id),
          ));
          walk(k.id, depth + 1);
        }
      }

      walk(null, 0);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder…'),
              onTap: () async {
                final n = await askName(ctx, 'New folder');
                if (n != null && ctx.mounted) {
                  Navigator.pop(ctx, store.createColl(n).id);
                }
              },
            ),
            ...rows,
          ]),
        ),
      );
    },
  );
}

/// Bulk actions on a set of video paths.
Future<void> bulkSheet(BuildContext c, List<String> paths, {String? inColl, VoidCallback? done}) {
  return showModalBottomSheet(
    context: c,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text('${paths.length} selected')),
        ListTile(
          leading: const Icon(Icons.drive_file_move_outline),
          title: const Text('Add to folder'),
          onTap: () async {
            Navigator.pop(ctx);
            final id = await pickCollection(c);
            if (id != null) store.addToColl(id, paths);
            done?.call();
          },
        ),
        if (inColl != null)
          ListTile(
            leading: const Icon(Icons.drive_file_move),
            title: const Text('Move to another folder'),
            onTap: () async {
              Navigator.pop(ctx);
              final id = await pickCollection(c, title: 'Move to', exclude: inColl);
              if (id != null) {
                store.addToColl(id, paths);
                store.removeFromColl(inColl, paths);
              }
              done?.call();
            },
          ),
        if (inColl != null)
          ListTile(
            leading: const Icon(Icons.remove_circle_outline),
            title: const Text('Remove from this folder'),
            onTap: () {
              store.removeFromColl(inColl, paths);
              Navigator.pop(ctx);
              done?.call();
            },
          ),
        ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: const Text('Mark as watched'),
          onTap: () {
            store.markMany(paths, true);
            Navigator.pop(ctx);
            done?.call();
          },
        ),
        ListTile(
          leading: const Icon(Icons.radio_button_unchecked),
          title: const Text('Mark as unwatched'),
          onTap: () {
            store.markMany(paths, false);
            Navigator.pop(ctx);
            done?.call();
          },
        ),
        ListTile(
          leading: const Icon(Icons.visibility_off_outlined),
          title: const Text('Hide from library'),
          subtitle: const Text('The files stay on your phone'),
          onTap: () {
            store.hide(paths);
            Navigator.pop(ctx);
            done?.call();
          },
        ),
      ]),
    ),
  );
}

Future<void> itemSheet(BuildContext c, Item i) {
  final pr = store.prog(i.path);
  return showModalBottomSheet(
    context: c,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(i.isEpisode ? '${i.name} · ${i.detail}' : i.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${p.basename(i.path)}\n${fmtSize(i.size)}',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            isThreeLine: true,
          ),
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text(pr != null && !pr.watched && pr.pos > 15000 ? 'Resume' : 'Play'),
            onTap: () {
              Navigator.pop(ctx);
              playItem(c, i);
            },
          ),
          if (pr != null && pr.pos > 15000)
            ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('Play from beginning'),
              onTap: () {
                Navigator.pop(ctx);
                playItem(c, i, fromStart: true);
              },
            ),
          ListTile(
            leading: Icon(pr?.watched == true ? Icons.radio_button_unchecked : Icons.check_circle_outline),
            title: Text(pr?.watched == true ? 'Mark as unwatched' : 'Mark as watched'),
            onTap: () {
              store.markWatched(i.path, pr?.watched != true);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Add to folder'),
            onTap: () async {
              Navigator.pop(ctx);
              final id = await pickCollection(c);
              if (id != null) store.addToColl(id, [i.path]);
            },
          ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Regenerate thumbnail'),
            onTap: () {
              thumbs.regen(i);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('Hide from library'),
            onTap: () {
              store.hide([i.path]);
              Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    ),
  );
}
