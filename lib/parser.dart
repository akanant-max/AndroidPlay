/// Turns a file name like "Show.Name.S02E05.Title.1080p.WEB-DL.x265" into
/// structured info (movie vs episode, year, season, episode).
class Parsed {
  final String title;
  final int? year, season, episode;
  final String? sub;
  const Parsed(this.title, {this.year, this.season, this.episode, this.sub});
}

final _ws = RegExp(r'\s+');
final _year = RegExp(r'\b(19|20)\d{2}\b');
final _se = <RegExp>[
  RegExp(r'\bS(\d{1,2})[ -]?E(\d{1,3})(?:[ -]?E\d{1,3})?\b', caseSensitive: false),
  RegExp(r'\bSeason[ -]?(\d{1,2})[ -]*Episode[ -]?(\d{1,3})\b',
      caseSensitive: false),
  RegExp(r'\b(\d{1,2})x(\d{2,3})\b', caseSensitive: false),
];
final _anime = RegExp(r'^(.*?)\s-\s(\d{1,3})(?:v\d)?(?:\s|$)');
final _junk = RegExp(
  r'\b(2160p|1080p|1080i|720p|576p|480p|4k|uhd|blu ray|bluray|bdrip|brrip|'
  r'bdremux|webrip|web dl|webdl|hdrip|dvdrip|hdtv|x264|x265|h 264|h 265|'
  r'h264|h265|hevc|avc|xvid|divx|aac|ac3|eac3|dts|ddp5|ddp|atmos|hdr10|hdr|'
  r'remux|proper|repack|extended|unrated|10bit|8bit|amzn|nf|dsnp|hmax)\b',
  caseSensitive: false,
);

String _cut(String s) {
  final m = _junk.firstMatch(s);
  return m == null ? s : s.substring(0, m.start);
}

String _clean(String s) => s
    .replaceAll(RegExp(r'^[\s\-–:]+|[\s\-–:]+$'), '')
    .replaceAll(_ws, ' ')
    .trim();

Parsed parseName(String base) {
  var s = base.replaceAll(RegExp(r'[._]'), ' ');
  // leading release-group tag like "[SubsPlease]"
  s = s.replaceFirst(RegExp(r'^\s*[\[\(][^\]\)]*[\]\)]\s*'), '');
  s = s.replaceAll(RegExp(r'[\[\]\(\)\{\}]'), ' ');
  s = s.replaceAll(_ws, ' ').trim();

  for (final re in _se) {
    final m = re.firstMatch(s);
    if (m != null) {
      final title = _clean(s.substring(0, m.start));
      final sub = _clean(_cut(s.substring(m.end)));
      return Parsed(
        title,
        season: int.parse(m.group(1)!),
        episode: int.parse(m.group(2)!),
        sub: sub.isEmpty ? null : sub,
      );
    }
  }

  final a = _anime.firstMatch(s);
  if (a != null && !_year.hasMatch(a.group(1)!) && a.group(1)!.trim().isNotEmpty) {
    return Parsed(_clean(a.group(1)!),
        season: 1, episode: int.parse(a.group(2)!));
  }

  int? year;
  var head = s;
  for (final y in _year.allMatches(s).toList().reversed) {
    if (y.start > 0) {
      year = int.parse(y.group(0)!);
      head = s.substring(0, y.start);
      break;
    }
  }
  var title = _clean(_cut(head));
  if (title.isEmpty) title = _clean(s);
  if (title.isEmpty) title = base;
  return Parsed(title, year: year);
}
