class Board {
  const Board(this.name, this.description);
  final String name;
  final String description;
}

const defaultBoards = [
  Board('C_Chat', '希洽・動漫與遊戲'),
  Board('PC_Shopping', '電蝦・電腦選購'),
  Board('MobileComm', '行動通訊'),
  Board('Soft_Job', '軟體工作'),
  Board('Tech_Job', '科技工作'),
  Board('Lifeismoney', '省錢生活'),
];

bool isBoardName(String value) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,19}$').hasMatch(value);

class ArticleSummary {
  const ArticleSummary({
    required this.board,
    required this.title,
    required this.author,
    required this.date,
    required this.score,
    required this.url,
    this.pinned = false,
    this.bbsIndex,
    this.bbsBottomOffset,
  });
  final String board, title, author, date, score;
  final Uri url;
  final bool pinned;
  // BBS lists provide a board-local number before Q resolves a stable AID.
  final int? bbsIndex, bbsBottomOffset;
  bool get fromBbs => bbsIndex != null || bbsBottomOffset != null;

  String? get aid {
    final match = RegExp(
      r'^M\.(\d+)\.A\.([\dA-Fa-f]{1,3})\.html$',
    ).firstMatch(url.pathSegments.last);
    if (match == null) return null;
    var value = (int.parse(match[1]!) << 12) | int.parse(match[2]!, radix: 16);
    const digits =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_';
    final result = List<String>.filled(8, '0');
    for (var i = 7; i >= 0; i--) {
      result[i] = digits[value & 63];
      value >>= 6;
    }
    return '#${result.join()}';
  }
}

class BoardPage {
  const BoardPage(this.articles, this.previousPage);
  final List<ArticleSummary> articles;
  final Uri? previousPage;
}

class PushComment {
  const PushComment(this.tag, this.author, this.content, this.time);
  final String tag, author, content, time;
}

class PttArticle {
  const PttArticle({
    required this.summary,
    required this.body,
    required this.comments,
    required this.postedAt,
  });
  final ArticleSummary summary;
  final String body, postedAt;
  final List<PushComment> comments;
}

class ArticleBlock {
  const ArticleBlock(this.text, this.urls);
  final String text;
  final List<Uri> urls;
}

List<Uri> extractUrls(String text) {
  final result = <Uri>[];
  final seen = <String>{};
  for (final match in RegExp(
    r'''https?://[^\s<>"'\u3000-\u303f\uff00-\uffef]+''',
    caseSensitive: false,
  ).allMatches(text)) {
    var raw = match[0]!;
    while (raw.isNotEmpty && '.,;:!?'.contains(raw[raw.length - 1])) {
      raw = raw.substring(0, raw.length - 1);
    }
    while (raw.endsWith(')') &&
        ')'.allMatches(raw).length > '('.allMatches(raw).length) {
      raw = raw.substring(0, raw.length - 1);
    }
    final uri = Uri.tryParse(raw);
    if (uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        seen.add(uri.toString())) {
      result.add(uri);
    }
  }
  return result;
}

List<ArticleBlock> articleBlocks(String body) {
  final seen = <String>{};
  return body
      .split(RegExp(r'\n[ \t]*\n'))
      .map((paragraph) {
        final urls = extractUrls(
          paragraph,
        ).where((url) => seen.add(url.toString())).toList();
        return ArticleBlock(paragraph.trimRight(), urls);
      })
      .where((block) => block.text.isNotEmpty)
      .toList();
}
