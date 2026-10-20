import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ptt_client/app.dart';
import 'package:ptt_client/app_model.dart';
import 'package:ptt_client/services/ptt_web.dart';
import 'package:ptt_client/services/ptt_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ptt_bbs_read_test.dart' show ReadingSocket;

void main() {
  final board = File('test/fixtures/board.html').readAsStringSync();
  final article = File('test/fixtures/article.html').readAsStringSync();

  Future<AppModel> model() async {
    SharedPreferences.setMockInitialValues({'previewPolicy': 0});
    final prefs = await SharedPreferences.getInstance();
    return AppModel(
      prefs,
      web: PttWeb(
        client: MockClient(
          (request) async => http.Response(
            request.url.path.contains('index') ? board : article,
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      ),
    );
  }

  testWidgets('mobile reads an article with URL cards and returns to board', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await model();
    await tester.runAsync(() => state.loadBoard('C_Chat'));
    await tester.pumpWidget(PttClientApp(model: state, loadOnStart: false));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('[討論] Windows 與 Android 的閱讀日常'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('在電腦上讀文章'), findsOneWidget);
    expect(find.text('載入預覽'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('公開看板・3 篇文章'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump();
  });

  testWidgets('desktop reader and settings fit without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = await model();
    await tester.runAsync(() => state.loadBoard('C_Chat'));
    await tester.pumpWidget(PttClientApp(model: state, loadOnStart: false));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('[討論] Windows 與 Android 的閱讀日常'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('在電腦上讀文章'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    expect(find.text('連結預覽載入方式'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    await tester.pump();
  });

  test(
    'late network responses cannot replace a newly selected board',
    () async {
      SharedPreferences.setMockInitialValues({'previewPolicy': 0});
      final first = Completer<http.Response>();
      final state = AppModel(
        await SharedPreferences.getInstance(),
        web: PttWeb(
          client: MockClient((request) async {
            if (request.url.path.contains('/C_Chat/')) return first.future;
            return http.Response(
              board.replaceAll('C_Chat', 'Soft_Job'),
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }),
        ),
      );
      final old = state.loadBoard('C_Chat');
      await state.loadBoard('Soft_Job');
      first.complete(
        http.Response(
          board,
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      );
      await old;
      expect(state.selectedBoard, 'Soft_Job');
      expect(state.articles.every((a) => a.board == 'Soft_Job'), isTrue);
      state.dispose();
    },
  );

  testWidgets(
    'desktop title click reads the authenticated BBS into the right pane',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'previewPolicy': 0});
      final socket = ReadingSocket()..truncatedTitle = true;
      final session = PttSession(
        connector: () async => socket,
        screenSettle: Duration.zero,
      );
      await tester.runAsync(
        () => session.login('tester1', 'test-only-password'),
      );
      final state = AppModel(
        await SharedPreferences.getInstance(),
        session: session,
        web: PttWeb(
          client: MockClient(
            (_) async => throw StateError('Unexpected public HTTP read'),
          ),
        ),
      );
      await tester.runAsync(() => state.loadBoard('C_Chat'));
      await tester.pumpWidget(PttClientApp(model: state, loadOnStart: false));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final done = Completer<void>();
        void loaded() {
          if (!state.loadingArticle &&
              state.selectedSummary != null &&
              !done.isCompleted) {
            done.complete();
          }
        }

        state.addListener(loaded);
        try {
          await tester.tap(find.text('[討論] test…'));
          await done.future.timeout(const Duration(seconds: 2));
        } finally {
          state.removeListener(loaded);
        }
      });
      await tester.pumpAndSettle();
      expect(state.articleError, isNull);
      expect(find.textContaining('本文第 4 行'), findsOneWidget);
      expect(find.text('載入預覽'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.disconnect);
      state.dispose();
      await tester.pump();
    },
  );
}
