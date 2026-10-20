// Optional documentation screenshots, using synthetic data only.
// Run: flutter test test/capture_ui_test.dart --dart-define=SCREENSHOT_FONT=/path/to/CJK-font.otf
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ptt_client/app.dart';
import 'package:ptt_client/app_model.dart';
import 'package:ptt_client/models/ptt_models.dart';
import 'package:ptt_client/services/link_preview.dart';
import 'package:ptt_client/services/ptt_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const font = String.fromEnvironment('SCREENSHOT_FONT');
  testWidgets('capture desktop and mobile documentation screenshots', (
    tester,
  ) async {
    if (font.isEmpty) return;
    await tester.runAsync(() async {
      final fontData = ByteData.sublistView(File(font).readAsBytesSync());
      for (final family in [
        'Roboto',
        'Microsoft JhengHei',
        'Noto Sans CJK TC',
      ]) {
        await (FontLoader(family)..addFont(Future.value(fontData))).load();
      }
      final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
      final icons = File(
        '${artifacts.path}/material_fonts/MaterialIcons-Regular.otf',
      );
      if (icons.existsSync()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(icons.readAsBytesSync())),
            ))
            .load();
      }
    });
    SharedPreferences.setMockInitialValues({'previewPolicy': 2});
    final board = File('test/fixtures/board.html').readAsStringSync();
    final article = File('test/fixtures/article.html').readAsStringSync();
    final model = AppModel(
      await SharedPreferences.getInstance(),
      web: PttWeb(
        client: MockClient(
          (request) async => http.Response(
            request.url.path.contains('index') ? board : article,
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      ),
      previews: LinkPreviewService(
        guard: UrlGuard(lookup: (_) async => [InternetAddress('8.8.8.8')]),
        client: MockClient(
          (_) async => http.Response(
            '<meta property="og:title" content="讓連結閱讀更順手"><meta property="og:description" content="短網址展開後，可以留在同一個 App 中查看完整網頁。">',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await model.loadBoard('C_Chat');
      await model.openArticle(model.articles.last);
      final source =
          '${model.article!.body}\n${model.article!.comments.map((p) => p.content).join("\n")}';
      for (final url in extractUrls(source)) {
        await model.previews.preview(url);
      }
    });
    final key = GlobalKey();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: PttClientApp(model: model, loadOnStart: false),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('docs/screenshots/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await tester.runAsync(() => capture('desktop'));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('[討論] Windows 與 Android 的閱讀日常'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => capture('android'));
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await tester.pump();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, skip: font.isEmpty);
}
