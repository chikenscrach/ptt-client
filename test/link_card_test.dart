import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ptt_client/app_model.dart';
import 'package:ptt_client/services/link_preview.dart';
import 'package:ptt_client/widgets/link_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'automatic card displays metadata and opens its resolved target',
    (tester) async {
      SharedPreferences.setMockInitialValues({'previewPolicy': 2});
      final service = LinkPreviewService(
        guard: UrlGuard(lookup: (_) async => [InternetAddress('8.8.8.8')]),
        client: MockClient(
          (_) async => http.Response(
            '<title>測試網頁</title>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );
      final model = AppModel(
        await SharedPreferences.getInstance(),
        previews: service,
      );
      final url = Uri.parse('https://example.com/a?x=1#part');
      await tester.runAsync(() => service.preview(url));
      Uri? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkCard(
              url: url,
              model: model,
              onOpen: (uri) => opened = uri,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('測試網頁'), findsOneWidget);
      await tester.tap(find.text('測試網頁'));
      expect(opened, url);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await tester.pump();
    },
  );

  testWidgets('failed manual preview keeps a clickable original URL', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'previewPolicy': 0});
    final service = LinkPreviewService(
      guard: UrlGuard(lookup: (_) async => [InternetAddress('8.8.8.8')]),
      client: MockClient((_) async => http.Response('', 403)),
    );
    final model = AppModel(
      await SharedPreferences.getInstance(),
      previews: service,
    );
    final url = Uri.parse('https://example.com/blocked');
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkCard(url: url, model: model, onOpen: (uri) => opened = uri),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('載入預覽'));
      await expectLater(
        service.preview(url).timeout(const Duration(seconds: 2)),
        throwsA(isA<PreviewException>()),
      );
    });
    await tester.pump();
    final cardFuture = tester
        .widget<FutureBuilder<LinkPreview?>>(
          find.byType(FutureBuilder<LinkPreview?>),
        )
        .future!;
    final value = await tester.runAsync(
      () => cardFuture.timeout(const Duration(seconds: 2)),
    );
    expect(value, isNull);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('無法取得卡片，仍可點擊開啟網頁'), findsOneWidget);
    await tester.tap(find.text(url.toString()));
    expect(opened, url);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await tester.pump();
  });
}
