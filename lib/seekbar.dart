import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models.dart';

/// Seek bar with small gaps at chapter starts. When chapters are crowded,
/// only marks at least [minGap] px apart are drawn so it never turns into
/// a row of slivers.
class SeekBar extends StatefulWidget {
  final ValueListenable<Duration> position;
  final Duration duration;
  final List<Chap> chapters;
  final VoidCallback onStart;
  final ValueChanged<Duration> onChanged;
  final ValueChanged<Duration> onEnd;
  /// Called with the time under the mouse / finger (null when it leaves).
  final ValueChanged<Duration?>? onHover;
  /// Small preview frame for the hovered / dragged time.
  final ValueListenable<Uint8List?>? preview;
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.chapters,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
    this.onHover,
    this.preview,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag, _hover;
  double _w = 1;

  int get _ms => widget.duration.inMilliseconds;
  double _frac(Offset l) => (l.dx / _w).clamp(0.0, 1.0).toDouble();
  Duration _at(double f) => Duration(milliseconds: (f * _ms).round());

  String? _chapterAt(Duration t) {
    String? name;
    final s = t.inMilliseconds / 1000;
    for (final c in widget.chapters) {
      if (c.time <= s + 0.01) name = c.title;
    }
    return name;
  }

  Widget _bubble(double f) {
    final t = _at(f);
    final ch = _chapterAt(t);
    const bw = 200.0;
    return Positioned(
      left: (f * _w - bw / 2).clamp(0.0, (_w - bw).clamp(0.0, double.infinity)).toDouble(),
      bottom: 30,
      width: bw,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xEE111116),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.preview != null)
              ValueListenableBuilder<Uint8List?>(
                valueListenable: widget.preview!,
                builder: (_, img, __) => img == null
                    ? const SizedBox.shrink()
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.memory(img,
                              fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 400),
                        ),
                      ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(fmt(t), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                if (ch != null)
                  Text(ch,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final fracs = _ms <= 0
        ? <double>[]
        : [for (final c in widget.chapters) c.time * 1000 / _ms];
    return LayoutBuilder(builder: (context, box) {
      _w = box.maxWidth;
      return MouseRegion(
        onHover: _ms <= 0
            ? null
            : (e) {
                setState(() => _hover = _frac(e.localPosition));
                widget.onHover?.call(_at(_hover!));
              },
        onExit: (_) {
          setState(() => _hover = null);
          if (_drag == null) widget.onHover?.call(null);
        },
        child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _ms <= 0
            ? null
            : (d) {
                setState(() => _drag = _frac(d.localPosition));
                widget.onStart();
                widget.onChanged(_at(_drag!));
                widget.onHover?.call(_at(_drag!));
              },
        onHorizontalDragUpdate: _ms <= 0
            ? null
            : (d) {
                setState(() => _drag = _frac(d.localPosition));
                widget.onChanged(_at(_drag!));
                widget.onHover?.call(_at(_drag!));
              },
        onHorizontalDragEnd: _ms <= 0
            ? null
            : (_) {
                final f = _drag;
                setState(() => _drag = null);
                if (f != null) widget.onEnd(_at(f));
                if (_hover == null) widget.onHover?.call(null);
              },
        onTapUp: _ms <= 0
            ? null
            : (d) {
                widget.onStart();
                widget.onEnd(_at(_frac(d.localPosition)));
              },
        child: SizedBox(
          height: 34,
          child: ValueListenableBuilder<Duration>(
            valueListenable: widget.position,
            builder: (context, pos, _) {
              final f = _drag ?? (_ms > 0 ? (pos.inMilliseconds / _ms).clamp(0.0, 1.0).toDouble() : 0.0);
              return Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SeekPainter(
                      fraction: f,
                      marks: fracs,
                      accent: accent,
                      active: _drag != null,
                    ),
                  ),
                ),
                if (_drag != null || _hover != null) _bubble(_drag ?? _hover!),
              ]);
            },
          ),
        ),
      ));
    });
  }
}

class _SeekPainter extends CustomPainter {
  final double fraction;
  final List<double> marks;
  final Color accent;
  final bool active;
  _SeekPainter({required this.fraction, required this.marks, required this.accent, required this.active});

  @override
  void paint(Canvas c, Size s) {
    final h = active ? 6.0 : 4.0;
    final y = s.height / 2;
    final w = s.width;
    // keep chapter marks that are far enough apart
    final minGap = marks.length > 30 ? 16.0 : 9.0;
    final kept = <double>[];
    var last = 0.0;
    for (final m in [...marks]..sort()) {
      final x = m * w;
      if (x < 6 || x > w - 6) continue;
      if (x - last < minGap) continue;
      kept.add(x);
      last = x;
    }
    // segments between kept marks, with a 3 px gap at each
    const gap = 1.5;
    final edges = <(double, double)>[];
    var from = 0.0;
    for (final x in kept) {
      edges.add((from, x - gap));
      from = x + gap;
    }
    edges.add((from, w));
    final px = fraction * w;
    final bg = Paint()..color = Colors.white24;
    final fg = Paint()..color = accent;
    final r = Radius.circular(h / 2);
    for (final (a, b) in edges) {
      if (b <= a) continue;
      c.drawRRect(RRect.fromLTRBR(a, y - h / 2, b, y + h / 2, r), bg);
      final e = px < b ? px : b;
      if (e > a) c.drawRRect(RRect.fromLTRBR(a, y - h / 2, e, y + h / 2, r), fg);
    }
    c.drawCircle(Offset(px, y), active ? 9 : 7, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekPainter o) =>
      o.fraction != fraction || o.active != active || o.marks.length != marks.length || o.accent != accent;
}
