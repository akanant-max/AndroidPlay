class Item {
  final String path, title;
  final int? year, season, episode;
  final String? show, sub;
  final int size, added;

  const Item({
    required this.path,
    required this.title,
    this.year,
    this.show,
    this.season,
    this.episode,
    this.sub,
    this.size = 0,
    this.added = 0,
  });

  bool get isEpisode => show != null && season != null && episode != null;

  String get epLabel =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  /// Main line on a card: movie title or show name.
  String get name =>
      isEpisode ? show! : (year != null ? '$title ($year)' : title);

  /// Second line on a card.
  String get detail => isEpisode
      ? '$epLabel${sub != null ? ' · $sub' : ''}'
      : (year?.toString() ?? '');

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'year': year,
        'show': show,
        'season': season,
        'episode': episode,
        'sub': sub,
        'size': size,
        'added': added,
      };

  factory Item.fromJson(Map j) => Item(
        path: j['path'] as String,
        title: j['title'] as String,
        year: j['year'] as int?,
        show: j['show'] as String?,
        season: j['season'] as int?,
        episode: j['episode'] as int?,
        sub: j['sub'] as String?,
        size: (j['size'] as int?) ?? 0,
        added: (j['added'] as int?) ?? 0,
      );
}

class Prog {
  int pos, dur, updated;
  bool watched;
  Prog({this.pos = 0, this.dur = 0, this.watched = false, this.updated = 0});

  double get frac => dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() =>
      {'p': pos, 'd': dur, 'w': watched, 'u': updated};

  factory Prog.fromJson(Map j) => Prog(
        pos: (j['p'] as int?) ?? 0,
        dur: (j['d'] as int?) ?? 0,
        watched: (j['w'] as bool?) ?? false,
        updated: (j['u'] as int?) ?? 0,
      );
}

class Chap {
  final String title;
  final double time;
  Chap(this.title, this.time);
}

String fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
