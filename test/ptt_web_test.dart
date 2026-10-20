import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ptt_client/models/ptt_models.dart';
import 'package:ptt_client/services/ptt_web.dart';

void main() {
  final boardHtml = File('test/fixtures/board.html').readAsStringSync();
  final articleHtml = File('test/fixtures/article.html').readAsStringSync();
  final boardUrl = Uri.parse('https://www.ptt.cc/bbs/C_Chat/index.html');

  test('board parses articles, deletion, pins and same-board pagination', () {
    final page = PttWeb.parseBoard(boardHtml, 'C_Chat', boardUrl);
    expect(page.articles.length, 3);
    expect(page.articles.first.pinned, isTrue);
    expect(page.articles.last.author, 'reader');
    expect(
      page.previousPage.toString(),
      'https://www.ptt.cc/bbs/C_Chat/index11.html',
    );
    expect(page.articles.last.aid, '#1YM4nv0j');
  });

  test(
    'article preserves colored text and line breaks; separates push comments',
    () {
      final summary = PttWeb.parseBoard(
        boardHtml,
        'C_Chat',
        boardUrl,
      ).articles.last;
      final article = PttWeb.parseArticle(articleHtml, summary);
      expect(article.body, contains('仍應保留的彩色文字'));
      expect(article.body, contains('\n\n分享'));
      expect(article.body, isNot(contains('alice')));
      expect(article.comments.length, 2);
      expect(article.comments.first.content, startsWith('希望可以預覽圖片'));
      expect(article.postedAt, 'Tue Oct 20 13:00:00 2026');
    },
  );

  test('age consent is explicit; no cookie before confirmation', () async {
    final cookies = <String?>[];
    final web = PttWeb(
      client: MockClient((request) async {
        cookies.add(request.headers['Cookie']);
        return request.headers['Cookie'] == null
            ? http.Response(
                '',
                302,
                headers: {'location': '/ask/over18?from=x'},
              )
            : http.Response(
                boardHtml,
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              );
      }),
    );
    await expectLater(
      web.board('C_Chat'),
      throwsA(isA<AgeConfirmationRequired>()),
    );
    web.over18 = true;
    expect((await web.board('C_Chat')).articles.length, 3);
    expect(cookies, [null, 'over18=1']);
    web.close();
  });

  test(
    'public reader cannot fetch another host or cross-board pagination',
    () async {
      final web = PttWeb(
        client: MockClient((_) async => throw StateError('must not fetch')),
      );
      await expectLater(
        web.board(
          'C_Chat',
          page: Uri.parse('https://evil.example/bbs/C_Chat/index.html'),
        ),
        throwsA(isA<PttWebException>()),
      );
      await expectLater(
        web.board(
          'C_Chat',
          page: Uri.parse('https://www.ptt.cc/bbs/Other/index.html'),
        ),
        throwsA(isA<PttWebException>()),
      );
      expect(
        PttWeb.isPttUrl(
          Uri.parse('https://www.ptt.cc@evil.example/bbs/C_Chat/index.html'),
        ),
        isFalse,
      );
      web.close();
    },
  );

  test(
    'URL extraction preserves queries, fragments and balanced parentheses',
    () {
      final urls = extractUrls(
        '看 https://example.com/a_(b)。\nhttps://example.com/q?a=1&b=2#part\n(https://example.com/x).',
      );
      expect(urls.map((u) => u.toString()), [
        'https://example.com/a_(b)',
        'https://example.com/q?a=1&b=2#part',
        'https://example.com/x',
      ]);
      expect(
        articleBlocks(
          'https://example.com\n\n重複 https://example.com',
        ).expand((b) => b.urls).length,
        1,
      );
      expect(isBoardName('C_Chat\rpassword'), isFalse);
    },
  );
}
