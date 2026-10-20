import '../models/ptt_models.dart';

/// Data formats on PTT's 80-column board list and article pager.
/// These parsers operate on our decoded screen, without an HTTP request.
class BbsListEntry {
  const BbsListEntry(this.summary, this.selected);
  final ArticleSummary summary;
  final bool selected;
}

class BbsArticlePage {
  const BbsArticlePage(this.lines, this.firstLine, this.lastLine, this.atEnd);
  final List<String> lines;
  final int? firstLine, lastLine;
  final bool atEnd;

  static BbsArticlePage? parse(String screen) {
    final rows = screen.split('\n');
    if (rows.length < 2) return null;
    final footer = rows.last;
    if (!RegExp(r'瀏覽\s*(?:第|P\.)|文章瀏覽|目前顯示').hasMatch(footer)) {
      return null;
    }
    final range = RegExp(r'第\s*(\d+)\s*[~～]\s*(\d+)\s*行').firstMatch(footer);
    final progress = RegExp(r'\(\s*(\d+)%\s*\)').firstMatch(footer);
    final pages = RegExp(r'第\s*(\d+)\s*/\s*(\d+)\s*頁').firstMatch(footer);
    final atEnd = progress != null
        ? int.parse(progress[1]!) >= 100
        : pages != null && pages[1] == pages[2];
    return BbsArticlePage(
      rows.take(rows.length - 1).toList(),
      range == null ? null : int.parse(range[1]!),
      range == null ? null : int.parse(range[2]!),
      atEnd,
    );
  }
}

class PttBbsParser {
  static List<BbsListEntry> board(String screen, String board) {
    final pattern = RegExp(
      r'^\s*([●>→]?)\s*(\d+|★)\s+(.*?)\s*(\d{1,2}/\d{1,2})\s+([A-Za-z0-9_-]+)\s+(□|R:|轉|鎖|ˇ|╳)\s*(.*)$',
    );
    final matches = screen
        .split('\n')
        .map(pattern.firstMatch)
        .whereType<RegExpMatch>()
        .toList();
    final entries = <BbsListEntry>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m[5] == '-' || m[6] == '╳') continue;
      final index = int.tryParse(m[2]!);
      final pinned = m[2] == '★';
      final offset = matches.length - i - 1;
      var title = m[7]!.trim();
      if (m[6] == 'R:') title = 'Re: $title';
      if (m[6] == '轉') title = 'Fw: $title';
      final score = RegExp(r'爆|XX|X\d+|\d+').firstMatch(m[3]!);
      entries.add(
        BbsListEntry(
          ArticleSummary(
            board: board,
            title: title,
            author: m[5]!,
            date: m[4]!,
            score: score?[0] ?? '',
            pinned: pinned,
            bbsIndex: index,
            bbsBottomOffset: pinned ? offset : null,
            url: Uri.https(
              'www.ptt.cc',
              '/bbs/$board/index.html',
              null,
            ).replace(fragment: 'bbs-${pinned ? "pinned-$offset" : index}'),
          ),
          m[1]!.isNotEmpty,
        ),
      );
    }
    return entries;
  }

  static Uri? articleUrl(String screen, String board) {
    final identity = RegExp(
      '#([0-9A-Za-z_-]{8})\\s+\\(${RegExp.escape(board)}\\)',
      caseSensitive: false,
    ).firstMatch(screen);
    if (identity == null) return null;
    var value = 0;
    const digits =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_';
    for (final rune in identity[1]!.runes) {
      value = (value << 6) | digits.indexOf(String.fromCharCode(rune));
    }
    final timestamp = value >> 12;
    final suffix = (value & 4095)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(3, '0');
    return Uri.https('www.ptt.cc', '/bbs/$board/M.$timestamp.A.$suffix.html');
  }

  static bool titleMatches(String full, String abbreviated) =>
      full.trimRight().startsWith(abbreviated.trimRight());

  static PttArticle article(
    List<BbsArticlePage> pages,
    ArticleSummary target,
    Uri url,
  ) {
    final numbered = <int, String>{};
    final sequential = <String>[];
    for (final page in pages) {
      if (page.firstLine != null && page.lastLine != null) {
        for (var i = 0; i < page.lines.length; i++) {
          final n = page.firstLine! + i;
          if (n <= page.lastLine!) numbered[n] = page.lines[i];
        }
      } else {
        var overlap = 0;
        // The legacy pager omits line numbers; keep its overlapping last row.
        for (var n = 1; n <= page.lines.length && n <= sequential.length; n++) {
          if (List.generate(
            n,
            (i) => sequential[sequential.length - n + i] == page.lines[i],
          ).every((same) => same)) {
            overlap = n;
          }
        }
        sequential.addAll(page.lines.skip(overlap));
      }
    }
    final keys = numbered.keys.toList()..sort();
    final lines = numbered.isEmpty
        ? sequential
        : keys.map((n) => numbered[n]!).toList();
    var title = target.title, author = target.author, postedAt = '';
    final body = <String>[];
    final comments = <PushComment>[];
    var afterFooter = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (i < 5) {
        final a = RegExp(r'^作者\s+(\S+)').firstMatch(line);
        final t = RegExp(r'^標題\s+(.+)').firstMatch(line);
        final d = RegExp(r'^時間\s+(.+)').firstMatch(line);
        if (a != null) {
          author = a[1]!;
          continue;
        }
        if (t != null) {
          title = t[1]!.trimRight();
          continue;
        }
        if (d != null) {
          postedAt = d[1]!.trimRight();
          continue;
        }
      }
      if (RegExp(r'^※\s*(發信站|文章網址)[:：]').hasMatch(line)) {
        afterFooter = true;
      }
      final push = afterFooter
          ? RegExp(r'^([推噓→])\s+([A-Za-z0-9_]+):\s?(.*)$').firstMatch(line)
          : null;
      if (push == null) {
        body.add(line);
      } else {
        final time = RegExp(
          r'\s+((?:(?:\d{1,3}\.){3}\d{1,3}\s+)?\d{1,2}/\d{1,2}\s+\d{2}:\d{2})\s*$',
        ).firstMatch(push[3]!);
        comments.add(
          PushComment(
            push[1]!,
            push[2]!,
            time == null ? push[3]! : push[3]!.substring(0, time.start),
            time?[1] ?? '',
          ),
        );
      }
    }
    return PttArticle(
      summary: ArticleSummary(
        board: target.board,
        title: title,
        author: author,
        date: target.date,
        score: target.score,
        pinned: target.pinned,
        bbsIndex: target.bbsIndex,
        bbsBottomOffset: target.bbsBottomOffset,
        url: url,
      ),
      body: body.join('\n').trim(),
      comments: comments,
      postedAt: postedAt,
    );
  }
}
