import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart3_big5/big5.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ptt_client/models/ptt_models.dart';
import 'package:ptt_client/services/ptt_bbs_parser.dart';
import 'package:ptt_client/services/ptt_session.dart';

class ReadingSocket extends Fake implements WebSocket {
  ReadingSocket({this.modernCaption = false});
  final bool modernCaption;
  final incoming = StreamController<dynamic>();
  final writes = <String>[];
  bool open = true, denied = false, mismatched = false;
  bool favorites = false,
      truncatedTitle = false,
      resumeAtEnd = false,
      splitPage = false;
  String selectedBoard = 'Gossiping';
  String board = 'C_Chat';
  int selected = 102;
  String get caption => modernCaption ? '文章列表' : '文章選讀';

  void chooser({bool prompt = false}) => emit([
    prompt ? '【 搜尋全站看板 】' : '【 我的最愛 】',
    prompt ? '請輸入看板名稱(按空白鍵自動搜尋): C_Chat' : '編號 看板 類別 中文敘述',
    '${selectedBoard == "Gossiping" ? ">" : " "} 1 ˇ Gossiping 綜合 八卦',
    '${selectedBoard == "C_Chat" ? ">" : " "} 2 ˇ C_Chat 閒談 希洽',
  ], '我的最愛 (a)增加看板 (d)刪除');

  void firstPage() {
    final lines = List.generate(23, (i) => '本文第 ${i + 1} 行');
    lines[0] = '作者 tester1 (測試) 看板 $board';
    lines[1] = '標題 [討論] test full title';
    lines[2] = '時間 Tue Oct 20 16:00:00 2026';
    lines[4] = '短網址 https://example.com/short';
    lines[19] = '※ 發信站: 批踢踢實業坊(ptt.cc)';
    lines[22] = '推 reader1: 第一則 10/20 16:01';
    emit(lines, '瀏覽 第 1/2 頁 ( 76%) 目前顯示: 第 01~23 行');
  }

  void lastPage() => emit([
    '推 reader1: 第一則 10/20 16:01',
    '→ reader2: 第二則 10/20 16:02',
  ], '瀏覽 第 2/2 頁 (100%) 目前顯示: 第 23~24 行');

  @override
  int get readyState => open ? WebSocket.open : WebSocket.closed;
  @override
  set pingInterval(Duration? value) {}

  void emit(List<String> lines, String footer) {
    final frame = StringBuffer('\x1b[2J\x1b[H');
    for (var i = 0; i < lines.length && i < 23; i++) {
      frame.write('\x1b[${i + 1};1H${lines[i]}');
    }
    frame.write('\x1b[24;1H$footer');
    scheduleMicrotask(() {
      if (open) incoming.add(utf8.encode(frame.toString()));
    });
  }

  void list() {
    if (selected < 100) {
      emit([
        '測試 看板《$board》',
        '[←]離開 [→]閱讀',
        for (var i = selected - 2; i <= selected; i++)
          '${i == selected ? "●" : " "} $i + 1 10/19 tester1 □ [討論] older $i',
      ], '$caption (y)回應(X)推文');
      return;
    }
    emit([
      '測試 看板《$board》',
      '[←]離開 [→]閱讀',
      '編號 日 期 作 者 文 章 標 題',
      '${selected == 100 ? "●" : " "} 100 + 1 10/20 tester1 □ [討論] older',
      '${selected == 101 ? "●" : " "} 101 +爆 10/20 tester1 □ [討論] ${mismatched ? "other" : "test"}${truncatedTitle ? "…" : ""}',
      '${selected == 102 ? "●" : " "} 102 m 9 10/20 tester2 R: [討論] newest',
      '  103     10/20 -       ╳ (本文已被刪除)',
    ], '$caption (y)回應(X)推文');
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final sub = incoming.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    scheduleMicrotask(
      () => incoming.add([
        ...ascii.encode('\x1b[24;1H'),
        ...Big5.encode('請輸入代號，或以 guest 參觀：'),
      ]),
    );
    return sub;
  }

  @override
  void add(dynamic bytes) {
    final value = utf8.decode(List<int>.from(bytes as List));
    writes.add(value);
    if (value == 'tester1,\r') {
      emit([], '請輸入您的密碼:');
    } else if (value == 'test-only-password\r') {
      emit(['【主功能表】'], '');
    } else if (value == 's') {
      favorites ? chooser(prompt: true) : emit([], '請輸入看板名稱：');
    } else if (value == '\x03' && favorites) {
      chooser();
    } else if (value == 'C_Chat\r' || value == 'Soft_Job\r') {
      board = value.trim();
      if (denied) {
        emit([], '您沒有進入此看板的權限！');
      } else if (favorites) {
        selectedBoard = board;
        chooser();
      } else {
        list();
      }
    } else if (value == '\$\x0c') {
      selected = 102;
      list();
    } else if (RegExp(r'^\d+\r\x0c$').hasMatch(value)) {
      selected = int.parse(value.substring(0, value.indexOf('\r')));
      list();
    } else if (value == '#1YM4nv0j\r\x0c') {
      selected = 101;
      list();
    } else if (value == 'Q') {
      // An overlay/delta, not a whole new terminal screen.
      scheduleMicrotask(
        () => incoming.add(
          utf8.encode(
            '\x1b[12;1H│ 文章代碼(AID): #1YM4nv0j ($board)\x1b[24;1H請按任意鍵繼續\x1b[K',
          ),
        ),
      );
    } else if (value == ' \x0c' || value == '\x1b[D') {
      list();
    } else if (value == '\r' && favorites) {
      favorites = false;
      list();
    } else if (value == '\r') {
      resumeAtEnd ? lastPage() : firstPage();
    } else if (value == '0\x0c') {
      firstPage();
    } else if (value == '\x1b[6~') {
      if (splitPage) {
        incoming.add(utf8.encode('\x1b[1;1H推 reader1: 第一則 10/20 16:01\x1b[K'));
        Timer(const Duration(milliseconds: 40), lastPage);
      } else {
        lastPage();
      }
    } else {
      throw StateError('Unexpected test command: ${jsonEncode(value)}');
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    open = false;
    if (!incoming.isClosed) await incoming.close();
  }
}

void main() {
  Future<PttSession> login(ReadingSocket socket) async {
    final session = PttSession(
      connector: () async => socket,
      screenSettle: Duration.zero,
      responseTimeout: const Duration(milliseconds: 500),
    );
    await session.login('tester1', 'test-only-password');
    addTearDown(() async {
      await session.disconnect();
      session.dispose();
    });
    return session;
  }

  test(
    'logged-in boards use BBS rows, scores, deletion filtering and pagination',
    () async {
      final socket = ReadingSocket();
      final session = await login(socket);
      final page = await session.readBoard('C_Chat');
      expect(page.articles.map((a) => a.bbsIndex), [102, 101, 100]);
      expect(page.articles[1].score, '爆');
      expect(page.articles.first.title, 'Re: [討論] newest');
      expect(page.previousPage?.scheme, 'ptt-bbs');
      expect(page.previousPage?.queryParameters['before'], '100');
      expect(socket.writes, contains('\$\x0c'));
      final older = await session.readBoard('C_Chat', page: page.previousPage);
      expect(older.articles.map((a) => a.bbsIndex), [99, 98, 97]);
      expect(older.previousPage?.queryParameters['before'], '97');
    },
  );

  test(
    'article reading resolves AID and merges overlapping pages with URL previews',
    () async {
      final socket = ReadingSocket();
      final session = await login(socket);
      final board = await session.readBoard('C_Chat');
      final result = await session.readArticle(board.articles[1]);
      expect(result.summary.aid, '#1YM4nv0j');
      expect(result.summary.url.path, '/bbs/C_Chat/M.1649953913.A.02D.html');
      expect(result.summary.title, '[討論] test full title');
      expect(result.body, contains('https://example.com/short'));
      expect(extractUrls(result.body).single.host, 'example.com');
      expect(result.comments.map((p) => p.author), ['reader1', 'reader2']);
      expect(result.comments.first.content, '第一則');
      expect(socket.writes.where((v) => v == '\x1b[6~').length, 1);
      expect(socket.writes, isNot(contains('X')));
      expect(session.busy, isFalse);
    },
  );

  test(
    'the board can be reloaded while the terminal is viewing an article',
    () async {
      final socket = ReadingSocket();
      final session = await login(socket);
      final board = await session.readBoard('C_Chat');
      await session.readArticle(board.articles[1]);
      final result = await session.readBoard('C_Chat');
      expect(result.articles.length, 3);
      expect(socket.writes, contains('\x1b[D'));
    },
  );

  test(
    'read requests are serialized without sending input into another request',
    () async {
      final socket = ReadingSocket();
      final session = await login(socket);
      final results = await Future.wait([
        session.readBoard('C_Chat'),
        session.readBoard('Soft_Job'),
      ]);
      expect(results[0].articles.every((a) => a.board == 'C_Chat'), isTrue);
      expect(results[1].articles.every((a) => a.board == 'Soft_Job'), isTrue);
      expect(session.busy, isFalse);
    },
  );

  test(
    'permission and unfamiliar prompts stop reads without sending write commands',
    () async {
      final socket = ReadingSocket()..denied = true;
      final session = await login(socket);
      await expectLater(
        session.readBoard('C_Chat'),
        throwsA(isA<PttSessionException>()),
      );
      final count = socket.writes.length;
      session.screen.clear();
      session.screen.add('編輯文章\x1b[24;1H請確認是否儲存');
      await expectLater(
        session.readBoard('C_Chat'),
        throwsA(isA<PttSessionException>()),
      );
      expect(socket.writes.length, count);
      expect(session.busy, isFalse);
    },
  );

  test('an index whose author or title changed is not opened', () async {
    final socket = ReadingSocket();
    final session = await login(socket);
    final board = await session.readBoard('C_Chat');
    socket.mismatched = true;
    await expectLater(
      session.readArticle(board.articles[1]),
      throwsA(isA<PttSessionException>()),
    );
    expect(socket.writes, isNot(contains('Q')));
    expect(socket.writes, isNot(contains('\r')));
  });

  test(
    'modern board-list captions support reading and returning from an article',
    () async {
      final socket = ReadingSocket(modernCaption: true);
      final session = await login(socket);
      final board = await session.readBoard('C_Chat');
      final result = await session.readArticle(board.articles[1]);
      expect(result.summary.aid, '#1YM4nv0j');
      final reloaded = await session.readBoard('C_Chat');
      expect(reloaded.articles.length, 3);
    },
  );

  test('a truncated board title still opens the full article', () async {
    final socket = ReadingSocket()..truncatedTitle = true;
    final session = await login(socket);
    final board = await session.readBoard('C_Chat');
    final result = await session.readArticle(board.articles[1]);
    expect(result.summary.title, '[討論] test full title');
    expect(result.body, contains('https://example.com/short'));
  });
  test('favorites search selects the board before entering it', () async {
    final socket = ReadingSocket()..favorites = true;
    final session = await login(socket);
    socket.chooser();
    await Future<void>.delayed(Duration.zero);
    final board = await session.readBoard('C_Chat');
    final article = await session.readArticle(board.articles[1]);
    expect(article.summary.aid, '#1YM4nv0j');
    expect(
      socket.writes.indexOf('C_Chat\r'),
      lessThan(socket.writes.indexOf('\r')),
    );
  });
  test(
    'an unfinished board search is cancelled before entering a fresh name',
    () async {
      final socket = ReadingSocket()..favorites = true;
      final session = await login(socket);
      socket.chooser(prompt: true);
      await Future<void>.delayed(Duration.zero);
      final board = await session.readBoard('C_Chat');
      expect(board.articles, isNotEmpty);
      expect(socket.writes, contains('\x03'));
      expect(socket.writes.where((v) => v == 's'), hasLength(1));
    },
  );
  test(
    'a saved pager position is rewound before collecting the article',
    () async {
      final socket = ReadingSocket()..resumeAtEnd = true;
      final session = await login(socket);
      final board = await session.readBoard('C_Chat');
      final result = await session.readArticle(board.articles[1]);
      expect(result.summary.title, '[討論] test full title');
      expect(result.body, contains('https://example.com/short'));
      expect(result.comments.map((p) => p.author), ['reader1', 'reader2']);
    },
  );
  test('a partial page redraw waits for the next footer', () async {
    final socket = ReadingSocket()..splitPage = true;
    final session = await login(socket);
    final board = await session.readBoard('C_Chat');
    final result = await session.readArticle(board.articles[1]);
    expect(result.comments.map((p) => p.author), ['reader1', 'reader2']);
    expect(socket.writes.where((v) => v == '\x1b[6~'), hasLength(1));
  });
  test(
    'legacy pager progress and title truncation are recognized without accepting unrelated titles',
    () {
      final first = BbsArticlePage.parse('body\n瀏覽 P.1(70%)')!;
      final last = BbsArticlePage.parse('end\n瀏覽 P.1(100%)')!;
      expect(first.atStart, isTrue);
      expect(last.follows(first), isTrue);
      expect(
        PttBbsParser.titleMatches('[討論] test full title', '[討論] test..'),
        isTrue,
      );
      expect(PttBbsParser.titleMatches('[討論] other', '[討論] test…'), isFalse);
      expect(PttBbsParser.titleMatches('unrelated', '…'), isFalse);
    },
  );

  test(
    'pinned board entries retain separate positions and AID decoding is exact',
    () {
      final entries = PttBbsParser.board('''看板《C_Chat》
   ★ m 爆  1/01 boardman □ [公告] 第一則
●  ★ m 10 10/20 boardman □ [公告] 第二則
文章選讀''', 'C_Chat');
      expect(entries.length, 2);
      expect(entries.map((e) => e.summary.bbsBottomOffset), [1, 0]);
      expect(entries.last.selected, isTrue);
      expect(
        PttBbsParser.articleUrl('文章代碼(AID): #1YM4nv0j (Other)', 'C_Chat'),
        isNull,
      );
    },
  );
}
