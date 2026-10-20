import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ptt_client/app_model.dart';
import 'package:ptt_client/models/ptt_models.dart';
import 'package:ptt_client/services/ptt_session.dart';
import 'package:ptt_client/services/ptt_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthenticatedSession extends PttSession {
  final boardsRead = <String>[];
  final articlesRead = <ArticleSummary>[];
  final loaded = Completer<void>();
  void finishLogin() {
    busy = true;
    status = SessionStatus.loggedIn;
    notifyListeners();
    busy = false;
    notifyListeners();
  }

  @override
  Future<BoardPage> readBoard(String name, {Uri? page}) async {
    boardsRead.add(name);
    if (!loaded.isCompleted) loaded.complete();
    return BoardPage([
      ArticleSummary(
        board: name,
        title: '[討論] BBS 文章',
        author: 'tester1',
        date: '10/20',
        score: '10',
        bbsIndex: 101,
        url: Uri.https(
          'www.ptt.cc',
          '/bbs/$name/index.html',
        ).replace(fragment: 'bbs-101'),
      ),
    ], null);
  }

  @override
  Future<PttArticle> readArticle(ArticleSummary target) async {
    articlesRead.add(target);
    return PttArticle(
      summary: ArticleSummary(
        board: target.board,
        title: target.title,
        author: target.author,
        date: target.date,
        score: target.score,
        bbsIndex: 101,
        url: Uri.https(
          'www.ptt.cc',
          '/bbs/${target.board}/M.1649953913.A.02D.html',
        ),
      ),
      body: '連結 https://example.com/short',
      comments: [],
      postedAt: '2026-10-20',
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'previewPolicy': 0}));

  test(
    'after login, pinned boards and articles never request the blocked public website',
    () async {
      var httpRequests = 0;
      final session = AuthenticatedSession()..status = SessionStatus.loggedIn;
      final state = AppModel(
        await SharedPreferences.getInstance(),
        session: session,
        web: PttWeb(
          client: MockClient((_) async {
            httpRequests++;
            return http.Response('', 403);
          }),
        ),
      );
      await state.loadBoard('C_Chat');
      expect(state.boardError, isNull);
      expect(state.boardFromSession, isTrue);
      await state.openArticle(state.articles.single);
      expect(state.articleError, isNull);
      expect(state.article!.body, contains('https://example.com/short'));
      expect(state.selectedSummary!.aid, '#1YM4nv0j');
      expect(state.articles.single.url, state.selectedSummary!.url);
      expect(httpRequests, 0);
      state.dispose();
    },
  );

  test(
    'finishing login automatically reloads a board that previously failed with HTTP 403',
    () async {
      final session = AuthenticatedSession();
      final state = AppModel(
        await SharedPreferences.getInstance(),
        session: session,
        web: PttWeb(client: MockClient((_) async => http.Response('', 403))),
      );
      await state.loadBoard('C_Chat');
      expect(state.boardError, contains('HTTP 403'));
      session.finishLogin();
      await session.loaded.future;
      await Future<void>.delayed(Duration.zero);
      expect(state.boardError, isNull);
      expect(state.articles.single.fromBbs, isTrue);
      expect(session.boardsRead, ['C_Chat']);
      state.dispose();
    },
  );

  test(
    'an old HTTP failure cannot overwrite the successful authenticated reload',
    () async {
      final oldResponse = Completer<http.Response>();
      final session = AuthenticatedSession();
      final state = AppModel(
        await SharedPreferences.getInstance(),
        session: session,
        web: PttWeb(client: MockClient((_) => oldResponse.future)),
      );
      final oldRequest = state.loadBoard('C_Chat');
      session.finishLogin();
      await session.loaded.future;
      await Future<void>.delayed(Duration.zero);
      oldResponse.complete(http.Response('', 403));
      await oldRequest;
      expect(state.boardError, isNull);
      expect(state.boardFromSession, isTrue);
      expect(state.articles.single.title, '[討論] BBS 文章');
      state.dispose();
    },
  );
}
