import 'dart:io';

import 'package:file_picker/file_picker.dart';
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

Future<void> playItems(BuildContext c, List<Item> q, int i) =>
    Navigator.of(c, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => PlayerPage(queue: q, index: i)),
    );

Future<void> playItem(BuildContext c, Item it) {
  final (q, i) = store.queueFor(it);
  return playItems(c, q, i);
}

Future<void> addFolderFlow(BuildContext c) async {
  if (!await ensureStorage()) {
    if (c.mounted) {
      ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
        content: Text('Storage access is needed to find your videos'),
      ));
    }
    return;
  }
  final dir = await FilePicker.platform.getDirectoryPath();
  if (dir != null) await store.addFolder(dir);
}

/// 16:9 picture with optional progress bar and badge.
class Thumb extends StatelessWidget {
  final Item? item;
  final String? artPath;
  final double progress;
  final bool watched;
  final int badge;
  const Thumb({
    super.key,
    this.item,
    this.artPath,
    this.progress = 0,
    this.watched = false,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
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
              child: const Icon(Icons.movie_outlined, color: Colors.white24, size: 34),
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
              if (progress > 0)
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: LinearProgressIndicator(
                    value: progress, minHeight: 3, backgroundColor: Colors.black54,
                  ),
                ),
              if (watched)
                const Positioned(
                  top: 6, right: 6,
                  child: Icon(Icons.check_circle, color: Colors.white, size: 18, shadows: [
                    Shadow(blurRadius: 4, color: Colors.black),
                  ]),
                )
              else if (badge > 0)
                Positioned(
                  top: 6, right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('$badge',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onPrimary,
                        )),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class MediaCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Item? artItem;
  final String? artPath;
  final double progress;
  final bool watched;
  final int badge;
  final VoidCallback onTap;
  final VoidCallback? onLong;
  const MediaCard({
    super.key,
    required this.title,
    this.subtitle,
    this.artItem,
    this.artPath,
    this.progress = 0,
    this.watched = false,
    this.badge = 0,
    required this.onTap,
    this.onLong,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLong,
      borderRadius: BorderRadius.circular(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Thumb(
          item: artItem, artPath: artPath, progress: progress,
          watched: watched, badge: badge,
        ),
        const SizedBox(height: 6),
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (subtitle != null)
          Text(subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ]),
    );
  }
}

Widget itemCard(BuildContext c, Item i, {bool showProgress = true}) {
  final pr = store.prog(i.path);
  return MediaCard(
    title: i.name,
    subtitle: i.detail.isEmpty ? null : i.detail,
    artItem: i,
    progress: showProgress && pr != null && !pr.watched ? pr.frac : 0,
    watched: pr?.watched ?? false,
    onTap: () => playItem(c, i),
    onLong: () => itemSheet(c, i),
  );
}

class Shelf extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const Shelf(this.title, this.children, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      SizedBox(
        height: 160,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: children.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => SizedBox(width: 200, child: children[i]),
        ),
      ),
    ]);
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool addButton;
  const EmptyState(this.icon, this.text, {super.key, this.addButton = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: Colors.white24),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60)),
          if (addButton) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => addFolderFlow(context),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add a folder'),
            ),
          ],
        ]),
      ),
    );
  }
}

Future<void> itemSheet(BuildContext c, Item i) {
  final pr = store.prog(i.path);
  return showModalBottomSheet(
    context: c,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
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
          title: const Text('Play'),
          onTap: () {
            Navigator.pop(ctx);
            playItem(c, i);
          },
        ),
        ListTile(
          leading: Icon(pr?.watched == true
              ? Icons.visibility_off_outlined
              : Icons.check_circle_outline),
          title: Text(pr?.watched == true ? 'Mark as unwatched' : 'Mark as watched'),
          onTap: () {
            store.markWatched(i.path, pr?.watched != true);
            Navigator.pop(ctx);
          },
        ),
        if (pr != null)
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Reset progress'),
            onTap: () {
              store.resetProg(i.path);
              Navigator.pop(ctx);
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
      ]),
    ),
  );
}
