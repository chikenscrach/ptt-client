import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/terminal.dart';

/// Fixed terminal cells, with a viewport that can fit, zoom and pan the grid.
class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.screen});
  final TerminalScreen screen;
  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final _transform = TransformationController();
  final _glyphs = <String, TextPainter>{};
  Size? _viewport;
  Size get _canvasSize => Size(
    widget.screen.columns * _TerminalPainter.cellWidth + 32,
    widget.screen.rows * _TerminalPainter.cellHeight + 32,
  );

  void _fit() {
    final viewport = _viewport;
    if (viewport == null || viewport.isEmpty) return;
    final scale = math
        .min(
          viewport.width / _canvasSize.width,
          viewport.height / _canvasSize.height,
        )
        .clamp(0.1, 3.0);
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        (viewport.width - _canvasSize.width * scale) / 2,
        (viewport.height - _canvasSize.height * scale) / 2,
        0,
      );
  }

  void _zoom(double factor) {
    final viewport = _viewport;
    if (viewport == null) return;
    final center = viewport.center(Offset.zero);
    final point = _transform.toScene(center);
    final scale = (_transform.value.getMaxScaleOnAxis() * factor).clamp(
      0.1,
      3.0,
    );
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        center.dx - point.dx * scale,
        center.dy - point.dy * scale,
        0,
      );
  }

  @override
  void dispose() {
    _transform.dispose();
    for (final painter in _glyphs.values) {
      painter.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: '縮小終端',
            onPressed: () => _zoom(1 / 1.2),
            icon: const Icon(Icons.remove, size: 20),
          ),
          IconButton(
            tooltip: '放大終端',
            onPressed: () => _zoom(1.2),
            icon: const Icon(Icons.add, size: 20),
          ),
          TextButton.icon(
            onPressed: _fit,
            icon: const Icon(Icons.fit_screen, size: 20),
            label: const Text('符合視窗'),
          ),
        ],
      ),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewport = constraints.biggest;
                if (_viewport != viewport) {
                  _viewport = viewport;
                  _fit();
                }
                return InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.1,
                  maxScale: 3,
                  boundaryMargin: const EdgeInsets.all(64),
                  child: Semantics(
                    label: 'PTT 終端畫面：${widget.screen.text}',
                    child: CustomPaint(
                      size: _canvasSize,
                      painter: _TerminalPainter(widget.screen, _glyphs),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ],
  );
}

class _TerminalPainter extends CustomPainter {
  _TerminalPainter(this.screen, this.glyphs);
  final TerminalScreen screen;
  final Map<String, TextPainter> glyphs;
  static const cellWidth = 10.0, cellHeight = 24.0, inset = 16.0;
  static const _colors = [
    Color(0xff080b0e),
    Color(0xffdf6d78),
    Color(0xff70d69c),
    Color(0xffe3cc7a),
    Color(0xff80a9e7),
    Color(0xffc19ce8),
    Color(0xff7ad4d9),
    Color(0xffd7dfe7),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (glyphs.length > 4096) {
      for (final painter in glyphs.values) {
        painter.dispose();
      }
      glyphs.clear();
    }
    // Paint all backgrounds first so trailing cells cannot cover wide glyphs.
    for (var row = 0; row < screen.rows; row++) {
      for (var col = 0; col < screen.columns; col++) {
        final cell = screen.cells[row][col];
        if (cell.bg != 0) {
          canvas.drawRect(
            Rect.fromLTWH(
              inset + col * cellWidth,
              inset + row * cellHeight,
              cellWidth,
              cellHeight,
            ),
            Paint()..color = _colors[cell.bg],
          );
        }
      }
    }
    for (var row = 0; row < screen.rows; row++) {
      for (var col = 0; col < screen.columns; col++) {
        final cell = screen.cells[row][col];
        if (cell.text.isEmpty || cell.text == ' ') continue;
        final key = '${cell.fg}/${cell.bold}/${cell.text}';
        final painter = glyphs.putIfAbsent(
          key,
          () => TextPainter(
            text: TextSpan(
              text: cell.text,
              style: TextStyle(
                fontFamily: defaultTargetPlatform == TargetPlatform.windows
                    ? 'Consolas'
                    : 'monospace',
                fontFamilyFallback: const [
                  'Noto Sans Mono CJK TC',
                  'Microsoft JhengHei',
                  'Noto Sans CJK TC',
                ],
                fontSize: 18,
                height: 1.2,
                color: cell.bold
                    ? Color.lerp(_colors[cell.fg], Colors.white, 0.25)
                    : _colors[cell.fg],
                fontWeight: cell.bold ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout(),
        );
        final width =
            TerminalScreen.runeWidth(cell.text.runes.first) * cellWidth;
        final scale = math.min(
          1.0,
          math.min(width / painter.width, cellHeight / painter.height),
        );
        canvas.save();
        canvas.translate(
          inset + col * cellWidth + (width - painter.width * scale) / 2,
          inset + row * cellHeight + (cellHeight - painter.height * scale) / 2,
        );
        canvas.scale(scale);
        painter.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
    canvas.drawRect(
      Rect.fromLTWH(
        inset + screen.column.clamp(0, screen.columns - 1) * cellWidth,
        inset + screen.row * cellHeight,
        cellWidth,
        cellHeight,
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _TerminalPainter oldDelegate) => true;
}
