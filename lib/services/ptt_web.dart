import 'dart:async';
import 'dart:convert';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import '../models/ptt_models.dart';
import 'native_http.dart';

class PttWebException implements Exception {
  const PttWebException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AgeConfirmationRequired extends PttWebException {
  const AgeConfirmationRequired() : super('此看板需要確認已滿 18 歲。');
}

class PttWeb {
  PttWeb({http.Client? client}) : _client = client ?? nativeClient();
  final http.Client _client;
  bool over18 = false;
  static final origin = Uri.parse('https://www.ptt.cc');

  static bool isPttUrl(Uri url) =>
      url.scheme == 'https' &&
      url.host == 'www.ptt.cc' &&
      url.userInfo.isEmpty &&
      (!url.hasPort || url.port == 443) &&
      RegExp(
        r'^/bbs/[A-Za-z][A-Za-z0-9_-]{0,19}/(?:index(?:\d+)?\.html|[MG]\.\d+\.A\.[A-Fa-f0-9]{1,3}\.html)$',
      ).hasMatch(url.path);

  Future<String> _get(Uri url) async {
    if (!isPttUrl(url)) throw const PttWebException('無效的 PTT 文章或看板網址。');
    final request = http.Request('GET', url)..followRedirects = false;
    request.headers['User-Agent'] =
        'ptt-client/0.1.1 (+https://github.com/chikenscrach/ptt-client)';
    if (over18) request.headers['Cookie'] = 'over18=1';
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.stream.listen(null).cancel();
        if ((response.headers['location'] ?? '').contains('over18')) {
          throw const AgeConfirmationRequired();
        }
        throw const PttWebException('PTT 回傳了非預期的轉址，請稍後再試。');
      }
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        if (response.statusCode == 403) {
          throw const PttWebException(
            'PTT 公開網頁拒絕讀取（HTTP 403）。請到「PTT 連線」登入，登入後會直接讀取看板。',
          );
        }
        throw PttWebException('PTT 暫時無法讀取（HTTP ${response.statusCode}）。');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 4 * 1024 * 1024) {
          throw const PttWebException('文章過大，請改用內建網頁瀏覽。');
        }
      }
      final source = utf8.decode(bytes, allowMalformed: true);
      if (source.contains('action="/ask/over18"')) {
        throw const AgeConfirmationRequired();
      }
      return source;
    } on TimeoutException {
      throw const PttWebException('PTT 連線逾時，請檢查網路後重試。');
    } on http.ClientException {
      throw const PttWebException('無法連線 PTT，請檢查網路後重試。');
    }
  }

  Future<BoardPage> board(String name, {Uri? page}) async {
    if (!isBoardName(name)) throw const PttWebException('看板名稱格式不正確。');
    final url = page ?? origin.resolve('/bbs/$name/index.html');
    if (url.pathSegments.length < 3 || url.pathSegments[1] != name) {
      throw const PttWebException('分頁與看板不符。');
    }
    return parseBoard(await _get(url), name, url);
  }

  Future<PttArticle> article(ArticleSummary summary) async =>
      parseArticle(await _get(summary.url), summary);

  static BoardPage parseBoard(String source, String name, Uri url) {
    final doc = html.parse(source);
    if (doc.querySelector('.b-list-container') == null) {
      throw const PttWebException('找不到此看板，或看板無法由公開網頁讀取。');
    }
    final articles = <ArticleSummary>[];
    for (final node in doc.querySelectorAll('.r-ent')) {
      final link = node.querySelector('.title a');
      final href = link?.attributes['href'];
      if (link == null || href == null) continue;
      final articleUrl = url.resolve(href);
      if (!isPttUrl(articleUrl)) continue;
      final separator = doc.querySelector('.r-list-sep');
      var isPinned = false;
      if (separator != null) {
        var prev = node.previousElementSibling;
        while (prev != null) {
          if (identical(prev, separator)) {
            isPinned = true;
            break;
          }
          prev = prev.previousElementSibling;
        }
      }
      articles.add(
        ArticleSummary(
          board: name,
          title: link.text.trim(),
          author: node.querySelector('.author')?.text.trim() ?? '-',
          date: node.querySelector('.date')?.text.trim() ?? '',
          score: node.querySelector('.nrec')?.text.trim() ?? '',
          url: articleUrl,
          pinned: isPinned,
        ),
      );
    }
    Uri? previous;
    for (final a in doc.querySelectorAll('.btn-group-paging a')) {
      if (a.text.contains('上頁') && a.attributes['href'] != null) {
        final candidate = url.resolve(a.attributes['href']!);
        if (isPttUrl(candidate) && candidate.pathSegments[1] == name) {
          previous = candidate;
        }
      }
    }
    return BoardPage(articles.reversed.toList(), previous);
  }

  static PttArticle parseArticle(String source, ArticleSummary summary) {
    final doc = html.parse(source);
    final main = doc.querySelector('#main-content');
    if (main == null) throw const PttWebException('文章已刪除，或無法由公開網頁讀取。');
    final comments = main
        .querySelectorAll('.push')
        .map(
          (node) => PushComment(
            node.querySelector('.push-tag')?.text.trim() ?? '→',
            node.querySelector('.push-userid')?.text.trim() ?? '',
            (node.querySelector('.push-content')?.text ?? '').replaceFirst(
              RegExp(r'^:\s?'),
              '',
            ),
            node.querySelector('.push-ipdatetime')?.text.trim() ?? '',
          ),
        )
        .toList();
    var postedAt = '';
    for (final meta in main.querySelectorAll('.article-metaline')) {
      if (meta.querySelector('.article-meta-tag')?.text == '時間') {
        postedAt = meta.querySelector('.article-meta-value')?.text ?? '';
      }
    }
    final copy = main.clone(true);
    for (final node in copy.querySelectorAll(
      '.article-metaline,.article-metaline-right,.push,script,style',
    )) {
      node.remove();
    }
    // Preserve original line breaks and preformatted ASCII art.
    String textOf(Node node) {
      if (node is Text) return node.data;
      if (node is Element && node.localName == 'br') return '\n';
      return node.nodes.map(textOf).join();
    }

    return PttArticle(
      summary: summary,
      body: textOf(copy).trim(),
      comments: comments,
      postedAt: postedAt,
    );
  }

  void close() => _client.close();
}
