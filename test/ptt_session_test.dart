import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart3_big5/big5.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ptt_client/models/ptt_models.dart';
import 'package:ptt_client/services/ptt_session.dart';

class ScriptedSocket extends Fake implements WebSocket {
  ScriptedSocket({
    this.duplicate = false,
    this.loseConfirmation = false,
    this.wrongArticle = false,
    this.wrongAid = false,
    this.modernCaption = false,
  });
  final bool duplicate, loseConfirmation, wrongArticle, wrongAid;
  final bool modernCaption;
  String get listCaption => modernCaption ? '文章列表' : '文章選讀';
  final incoming = StreamController<dynamic>();
  final writes = <String>[];
  var _open = true;
  var _step = 0;
  @override
  int get readyState => _open ? WebSocket.open : WebSocket.closed;
  @override
  set pingInterval(Duration? value) {}

  void emit(String body, [String bottom = '']) {
    scheduleMicrotask(() {
      if (!_open) return;
      incoming.add(utf8.encode('\x1b[2J\x1b[H$body\x1b[24;1H$bottom'));
    });
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
  void add(dynamic data) {
    final value = utf8.decode(List<int>.from(data as List));
    writes.add(value);
    switch (_step++) {
      case 0:
        expect(value, 'tester1,\r');
        emit('', '請輸入您的密碼:');
      case 1:
        expect(value, 'test-only-password\r');
        if (duplicate) {
          emit('', '您想刪除其他重複登入的連線嗎？ [y/N]');
        } else {
          emit('【主功能表】');
        }
      case 2:
        expect(value, 's');
        emit('', '請輸入看板名稱：');
      case 3:
        expect(value, 'C_Chat\r');
        emit('看板《C_Chat》 $listCaption');
      case 4:
        expect(value, '#1YM4nv0j\r');
        emit('看板《C_Chat》 $listCaption');
      case 5:
        expect(value, 'Q');
        emit(
          '文章代碼(AID): ${wrongAid ? "#1YM4nv0k" : "#1YM4nv0j"} (C_Chat)',
          '請按任意鍵繼續',
        );
      case 6:
        expect(value, ' ');
        emit('看板《C_Chat》 $listCaption');
      case 7:
        expect(value, '\r');
        emit(
          '作者 tester1 看板 C_Chat\n標題 ${wrongArticle ? "[討論] another" : "[討論] test"}',
          '文章瀏覽 第 1/1 頁',
        );
      case 8:
        expect(value, 'X');
        emit('', '您覺得這篇文章 1.推 2.噓 3.→ [1]?');
      case 9:
        expect(value, '1');
        emit('', '推 tester1:');
      case 10:
        expect(value, '測試\r');
        emit('', '推 tester1:測試 確定[y/N]:');
      case 11:
        expect(value, 'y\r');
        if (!loseConfirmation) {
          emit('作者 tester1 看板 C_Chat\n標題 [討論] test', '文章瀏覽 第 1/1 頁');
        }
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _open = false;
    if (!incoming.isClosed) await incoming.close();
  }
}

void main() {
  final article = ArticleSummary(
    board: 'C_Chat',
    title: '[討論] test',
    author: 'tester1',
    date: '',
    score: '',
    url: Uri.parse('https://www.ptt.cc/bbs/C_Chat/M.1649953913.A.02D.html'),
  );

  test('login negotiates UTF-8 then navigates and confirms one push', () async {
    final socket = ScriptedSocket();
    final session = PttSession(connector: () async => socket);
    await session.login('tester1', 'test-only-password');
    expect(session.loggedIn, isTrue);
    await session.postComment(article, 1, '測試');
    expect(socket.writes.where((v) => v == 'y\r').length, 1);
    expect(socket.writes.where((v) => v == 'test-only-password\r').length, 1);
    await session.disconnect();
    session.dispose();
  });

  test('duplicate login prompt never auto-kicks another session', () async {
    final socket = ScriptedSocket(duplicate: true);
    final session = PttSession(connector: () async => socket);
    await session.login('tester1', 'test-only-password');
    expect(session.loggedIn, isFalse);
    expect(socket.writes.length, 2);
    expect(session.message, contains('額外的登入提示'));
    await session.disconnect();
    session.dispose();
  });

  test(
    'article verification and push support the modern board-list caption',
    () async {
      final socket = ScriptedSocket(modernCaption: true);
      final session = PttSession(connector: () async => socket);
      await session.login('tester1', 'test-only-password');
      await session.postComment(article, 1, '測試');
      expect(socket.writes.where((v) => v == 'y\r').length, 1);
      await session.disconnect();
      session.dispose();
    },
  );

  test('wrong target article prevents any push command', () async {
    final socket = ScriptedSocket(wrongArticle: true);
    final session = PttSession(connector: () async => socket);
    await session.login('tester1', 'test-only-password');
    await expectLater(
      session.postComment(article, 1, '測試'),
      throwsA(isA<PttSessionException>()),
    );
    expect(socket.writes, isNot(contains('X')));
    await session.disconnect();
    session.dispose();
  });

  test(
    'a different AID is rejected even when the title is unchanged',
    () async {
      final socket = ScriptedSocket(wrongAid: true);
      final session = PttSession(connector: () async => socket);
      await session.login('tester1', 'test-only-password');
      await expectLater(
        session.postComment(article, 1, '測試'),
        throwsA(predicate((error) => error.toString().contains('文章代碼與目標不符'))),
      );
      expect(socket.writes, isNot(contains('X')));
      expect(socket.writes, isNot(contains('y\r')));
      await session.disconnect();
      session.dispose();
    },
  );

  test('unknown result after final confirmation never resends', () async {
    final socket = ScriptedSocket(loseConfirmation: true);
    final session = PttSession(
      connector: () async => socket,
      responseTimeout: const Duration(milliseconds: 60),
    );
    await session.login('tester1', 'test-only-password');
    await expectLater(
      session.postComment(article, 1, '測試'),
      throwsA(predicate((e) => e.toString().contains('請勿直接重送'))),
    );
    expect(socket.writes.where((v) => v == 'y\r').length, 1);
    expect(session.busy, isFalse);
    await session.disconnect();
    session.dispose();
  });
}
