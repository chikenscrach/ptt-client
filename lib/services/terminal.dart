import 'dart:convert';
import 'package:dart3_big5/big5.dart';

class _StringSink implements Sink<String> {
  _StringSink(this.output);
  final List<String> output;
  @override
  void add(String data) => output.add(data);
  @override
  void close() {}
}

/// Carries incomplete multibyte characters across WebSocket frames.
class PttWireDecoder {
  bool _utf8 = false;
  int? _big5Lead;
  final _output = <String>[];
  late final ByteConversionSink _decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(_StringSink(_output));

  void useUtf8() {
    _big5Lead = null;
    _utf8 = true;
  }

  String add(List<int> bytes) {
    if (_utf8) {
      _decoder.add(bytes);
      final text = _output.join();
      _output.clear();
      return text;
    }
    final result = StringBuffer();
    for (final b in bytes) {
      if (_big5Lead != null) {
        final lead = _big5Lead!;
        _big5Lead = null;
        if (b >= 0x40 && b <= 0x7e || b >= 0xa1 && b <= 0xfe) {
          try {
            result.write(Big5.decode([lead, b]));
          } catch (_) {
            result.write('�');
          }
          continue;
        }
        result.write('�');
      }
      if (b >= 0x81 && b <= 0xfe) {
        _big5Lead = b;
      } else if (b < 128) {
        result.writeCharCode(b);
      } else {
        result.write('�');
      }
    }
    return result.toString();
  }
}

/// Stateful Telnet negotiation. IAC/SB sequences may span multiple frames.
class TelnetDecoder {
  TelnetDecoder(this.reply);
  final void Function(List<int>) reply;
  int _state = 0, _command = 0;
  final _sub = <int>[];

  List<int> add(List<int> bytes) {
    final output = <int>[];
    for (final b in bytes) {
      switch (_state) {
        case 0:
          if (b == 255) {
            _state = 1;
          } else {
            output.add(b);
          }
        case 1:
          if (b == 255) {
            output.add(255);
            _state = 0;
          } else if ([251, 252, 253, 254].contains(b)) {
            _command = b;
            _state = 2;
          } else if (b == 250) {
            _sub.clear();
            _state = 3;
          } else {
            _state = 0;
          }
        case 2:
          if (_command == 253) {
            final supported = b == 24 || b == 31 || b == 3;
            reply([255, supported ? 251 : 252, b]);
            if (b == 31) reply([255, 250, 31, 0, 80, 0, 24, 255, 240]);
          } else if (_command == 251) {
            reply([255, b == 1 || b == 3 ? 253 : 254, b]);
          }
          _state = 0;
        case 3:
          if (b == 255) {
            _state = 4;
          } else if (_sub.length < 256) {
            _sub.add(b);
          }
        case 4:
          if (b == 240) {
            if (_sub.length >= 2 && _sub[0] == 24 && _sub[1] == 1) {
              reply([255, 250, 24, 0, ...ascii.encode('VT100'), 255, 240]);
            }
            _state = 0;
          } else {
            if (b == 255 && _sub.length < 256) _sub.add(255);
            _state = 3;
          }
      }
    }
    return output;
  }
}

class TerminalCell {
  const TerminalCell([
    this.text = ' ',
    this.fg = 7,
    this.bg = 0,
    this.bold = false,
  ]);
  final String text;
  final int fg, bg;
  final bool bold;
}

/// An independent, bounded 80x24 VT screen, with CJK column widths.
class TerminalScreen {
  TerminalScreen({this.columns = 80, this.rows = 24, this.reply}) {
    cells = List.generate(rows, (_) => _blankLine());
    _bottom = rows - 1;
  }
  final int columns, rows;
  final void Function(String)? reply;
  late List<List<TerminalCell>> cells;
  int row = 0, column = 0;
  int _savedRow = 0, _savedColumn = 0, _top = 0, _bottom = 23;
  int _fg = 7, _bg = 0;
  bool _bold = false;
  String _escape = '';
  bool _osc = false, _oscEscape = false;
  static final _symbolWidths = <int, int>{};

  List<TerminalCell> _blankLine() => List.filled(columns, const TerminalCell());
  String get text =>
      cells.map((r) => r.map((c) => c.text).join().trimRight()).join('\n');
  String get bottomText =>
      cells.skip(rows - 4).map((r) => r.map((c) => c.text).join()).join('\n');

  void clear() {
    cells = List.generate(rows, (_) => _blankLine());
    row = column = 0;
    _fg = 7;
    _bg = 0;
    _bold = false;
    _top = 0;
    _bottom = rows - 1;
    _escape = '';
    _osc = false;
  }

  void add(String input) {
    for (final rune in input.runes) {
      if (_osc) {
        if (rune == 7 || _oscEscape && rune == 92) {
          _osc = false;
        }
        _oscEscape = rune == 27;
        continue;
      }
      if (_escape.isNotEmpty) {
        _escape += String.fromCharCode(rune);
        if (_escape == '\x1b]') {
          _osc = true;
          _escape = '';
          continue;
        }
        if (_escape == '\x1b[' || _escape == '\x1b(' || _escape == '\x1b)') {
          continue;
        }
        if (_escape.startsWith('\x1b[')) {
          if (rune >= 0x40 && rune <= 0x7e) {
            _csi(_escape);
            _escape = '';
          } else if (_escape.length > 96) {
            _escape = '';
          }
        } else {
          switch (_escape) {
            case '\x1b7':
              _savedRow = row;
              _savedColumn = column;
            case '\x1b8':
              row = _savedRow;
              column = _savedColumn;
            case '\x1bD':
              _lineFeed();
            case '\x1bE':
              column = 0;
              _lineFeed();
            case '\x1bM':
              if (row == _top) {
                cells.removeAt(_bottom);
                cells.insert(_top, _blankLine());
              } else {
                row = (row - 1).clamp(0, rows - 1);
              }
            case '\x1bc':
              clear();
          }
          _escape = '';
        }
        continue;
      }
      switch (rune) {
        case 27:
          _escape = '\x1b';
        case 13:
          column = 0;
        case 10:
          _lineFeed();
        case 8:
          column = (column - 1).clamp(0, columns - 1);
        case 9:
          column = ((column ~/ 8 + 1) * 8).clamp(0, columns);
        default:
          if (rune >= 32 && rune != 127) _put(rune);
      }
    }
  }

  static int runeWidth(int rune) {
    if (rune >= 0x300 && rune <= 0x36f ||
        rune == 0x200d ||
        rune >= 0xfe00 && rune <= 0xfe0f) {
      return 0;
    }
    // PTT still uses Big5 cell positions after negotiating UTF-8. Its arrows,
    // box drawing, bullets and other legacy symbols occupy two columns too.
    if (rune >= 0x80 && rune < 0x2e80) {
      return _symbolWidths.putIfAbsent(rune, () {
        final text = String.fromCharCode(rune);
        try {
          final bytes = Big5.encode(text);
          if (bytes.length == 2 && Big5.decode(bytes) == text) return 2;
        } catch (_) {
          // Use the Unicode wide ranges below for characters outside Big5.
        }
        return _unicodeWidth(rune);
      });
    }
    return _unicodeWidth(rune);
  }

  static int _unicodeWidth(int rune) {
    return rune >= 0x1100 &&
            (rune <= 0x115f ||
                rune == 0x2329 ||
                rune == 0x232a ||
                rune >= 0x2e80 && rune <= 0xa4cf ||
                rune >= 0xac00 && rune <= 0xd7a3 ||
                rune >= 0xf900 && rune <= 0xfaff ||
                rune >= 0xfe10 && rune <= 0xfe6f ||
                rune >= 0xff00 && rune <= 0xff60 ||
                rune >= 0xffe0 && rune <= 0xffe6 ||
                rune >= 0x1f300 && rune <= 0x1faff ||
                rune >= 0x20000 && rune <= 0x3fffd)
        ? 2
        : 1;
  }

  void _put(int rune) {
    final width = runeWidth(rune);
    if (width == 0) return;
    if (column + width > columns) {
      column = 0;
      _lineFeed();
    }
    // Erase either half of a previous wide character before replacing it.
    if (cells[row][column].text.isEmpty && column > 0) {
      cells[row][column - 1] = const TerminalCell();
    }
    if (column + 1 < columns && cells[row][column + 1].text.isEmpty) {
      cells[row][column + 1] = const TerminalCell();
    }
    cells[row][column] = TerminalCell(
      String.fromCharCode(rune),
      _fg,
      _bg,
      _bold,
    );
    if (width == 2) cells[row][column + 1] = TerminalCell('', _fg, _bg, _bold);
    column += width;
  }

  void _lineFeed() {
    if (row == _bottom) {
      cells.removeAt(_top);
      cells.insert(_bottom, _blankLine());
    } else {
      row = (row + 1).clamp(0, rows - 1);
    }
  }

  void _csi(String code) {
    final end = code[code.length - 1];
    final raw = code.substring(2, code.length - 1);
    if (raw.startsWith('?')) return;
    final p = raw.split(';').map((v) => int.tryParse(v) ?? 0).toList();
    int at(int index, [int fallback = 1]) =>
        p.length > index && p[index] > 0 ? p[index] : fallback;
    final count = at(0).clamp(1, 999);
    switch (end) {
      case 'A':
        row = (row - count).clamp(0, rows - 1);
      case 'B':
        row = (row + count).clamp(0, rows - 1);
      case 'C':
        column = (column + count).clamp(0, columns - 1);
      case 'D':
        column = (column - count).clamp(0, columns - 1);
      case 'E':
        row = (row + count).clamp(0, rows - 1);
        column = 0;
      case 'F':
        row = (row - count).clamp(0, rows - 1);
        column = 0;
      case 'G':
        column = (at(0) - 1).clamp(0, columns - 1);
      case 'd':
        row = (at(0) - 1).clamp(0, rows - 1);
      case 'H' || 'f':
        row = (at(0) - 1).clamp(0, rows - 1);
        column = (at(1) - 1).clamp(0, columns - 1);
      case 's':
        _savedRow = row;
        _savedColumn = column;
      case 'u':
        row = _savedRow;
        column = _savedColumn;
      case 'J':
        final mode = p[0];
        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < columns; c++) {
            if (mode >= 2 ||
                mode == 0 && (r > row || r == row && c >= column) ||
                mode == 1 && (r < row || r == row && c <= column)) {
              cells[r][c] = const TerminalCell();
            }
          }
        }
      case 'K':
        for (var c = 0; c < columns; c++) {
          if (p[0] == 2 ||
              p[0] == 0 && c >= column ||
              p[0] == 1 && c <= column) {
            cells[row][c] = const TerminalCell();
          }
        }
      case 'm':
        for (final value in p) {
          if (value == 0) {
            _fg = 7;
            _bg = 0;
            _bold = false;
          } else if (value == 1) {
            _bold = true;
          } else if (value == 22) {
            _bold = false;
          } else if (value >= 30 && value <= 37) {
            _fg = value - 30;
          } else if (value >= 40 && value <= 47) {
            _bg = value - 40;
          } else if (value >= 90 && value <= 97) {
            _fg = value - 90;
            _bold = true;
          } else if (value == 39) {
            _fg = 7;
          } else if (value == 49) {
            _bg = 0;
          } else if (value == 7) {
            final swap = _fg;
            _fg = _bg;
            _bg = swap;
          }
        }
      case 'r':
        _top = (at(0) - 1).clamp(0, rows - 1);
        _bottom = (at(1, rows) - 1).clamp(_top, rows - 1);
        row = column = 0;
      case 'P':
        final c = column.clamp(0, columns - 1);
        for (var i = 0; i < count && i < columns; i++) {
          cells[row].removeAt(c);
          cells[row].add(const TerminalCell());
        }
      case '@':
        for (var i = 0; i < count && i < columns; i++) {
          cells[row].insert(column.clamp(0, columns - 1), const TerminalCell());
          cells[row].removeLast();
        }
      case 'X':
        for (var c = column; c < (column + count).clamp(0, columns); c++) {
          cells[row][c] = const TerminalCell();
        }
      case 'L':
        for (var i = 0; i < count && i < rows; i++) {
          cells.removeAt(_bottom);
          cells.insert(row.clamp(_top, _bottom), _blankLine());
        }
      case 'M':
        for (var i = 0; i < count && i < rows; i++) {
          cells.removeAt(row.clamp(_top, _bottom));
          cells.insert(_bottom, _blankLine());
        }
      case 'n':
        if (p[0] == 6) reply?.call('\x1b[${row + 1};${column + 1}R');
      case 'c':
        reply?.call('\x1b[?1;2c');
    }
  }
}
