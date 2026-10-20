import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ptt_client/services/terminal.dart';
import 'package:ptt_client/widgets/terminal_view.dart';

void main() {
  testWidgets(
    'highlight backgrounds do not erase the right half of a wide glyph',
    (tester) async {
      final screen = TerminalScreen()..add('\x1b[31;47m中\x1b[0m\x1b[2;1H');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TerminalView(screen: screen)),
        ),
      );
      final widget = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(InteractiveViewer),
          matching: find.byType(CustomPaint),
        ),
      );
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        widget.painter!.paint(Canvas(recorder), widget.size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          widget.size.width.toInt(),
          widget.size.height.toInt(),
        );
        final data = await image.toByteData();
        var foregroundPixels = 0;
        // Inspect the right-hand cell of the first double-width character.
        for (var y = 16; y < 40; y++) {
          for (var x = 26; x < 36; x++) {
            final p = (y * image.width + x) * 4;
            if (data!.getUint8(p) == 0xdf &&
                data.getUint8(p + 1) == 0x6d &&
                data.getUint8(p + 2) == 0x78) {
              foregroundPixels++;
            }
          }
        }
        expect(foregroundPixels, greaterThan(10));
        image.dispose();
        picture.dispose();
      });
    },
  );
  testWidgets(
    'terminal zoom can reset and follows height-only window resizing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 500);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TerminalView(screen: TerminalScreen())),
        ),
      );
      TransformationController controller() => tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final initial = controller().value.getMaxScaleOnAxis();
      await tester.tap(find.byTooltip('放大終端'));
      await tester.pump();
      expect(controller().value.getMaxScaleOnAxis(), greaterThan(initial));
      await tester.tap(find.text('符合視窗'));
      await tester.pump();
      expect(controller().value.getMaxScaleOnAxis(), closeTo(initial, 0.001));
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pump();
      expect(controller().value.getMaxScaleOnAxis(), greaterThan(initial));
      expect(tester.takeException(), isNull);
    },
  );
}
