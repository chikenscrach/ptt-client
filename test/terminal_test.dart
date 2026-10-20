import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ptt_client/services/terminal.dart';
import 'package:ptt_client/services/ptt_session.dart';

void main() {
  test('Big5 and UTF-8 survive fragmented network frames', () {
    final decoder = PttWireDecoder();
    expect(decoder.add([0xa4]), '');
    expect(decoder.add([0xa4, 0xa4, 0xe5]), '中文');
    decoder.useUtf8();
    final result = StringBuffer();
    for (final byte in utf8.encode('中文あ😀')) {
      result.write(decoder.add([byte]));
    }
    expect(result.toString(), '中文あ😀');
  });
  test('fragmented Telnet negotiation handles NAWS and terminal type', () {
    final replies = <List<int>>[];
    final telnet = TelnetDecoder(replies.add);
    expect(telnet.add([255, 253]), isEmpty);
    expect(telnet.add([31, 65]), [65]);
    expect(replies, [
      [255, 251, 31],
      [255, 250, 31, 0, 80, 0, 24, 255, 240],
    ]);
    telnet.add([255, 250, 24, 1, 255]);
    telnet.add([240]);
    expect(replies.last, [255, 250, 24, 0, ...ascii.encode('VT100'), 255, 240]);
    telnet.add([255, 253, 99]);
    expect(replies.last, [255, 252, 99]);
  });
  test(
    'ANSI redraw positions Chinese using two columns and preserves colors',
    () {
      final screen = TerminalScreen();
      screen.add('\x1b[2J\x1b[');
      screen.add('3;5H\x1b[31m中A');
      expect(screen.cells[2][4].text, '中');
      expect(screen.cells[2][5].text, '');
      expect(screen.cells[2][6].text, 'A');
      expect(screen.cells[2][6].fg, 1);
      screen.add('\r\x1b[2K下一頁');
      expect(screen.text.split('\n')[2], '下一頁');
    },
  );
  test('screen scrolls without growing; OSC does not enter visible text', () {
    final screen = TerminalScreen(rows: 3, columns: 10);
    screen.add('one\r\ntwo\r\nthree\r\nfour');
    expect(screen.text, 'two\nthree\nfour');
    screen.add('\x1b]0;not-visible\x07');
    expect(screen.text, isNot(contains('not-visible')));
    screen.add('\x1b[2;2HX');
    expect(screen.cells[1][1].text, 'X');
  });
  test('push text rejects controls, oversized text and unsupported emoji', () {
    final session = PttSession()..username = 'reader';
    session.validateComment('測試推文');
    for (final text in [
      'hello\ry\r',
      'hello\x1b[D',
      '😀',
      List.filled(50, '中').join(),
    ]) {
      expect(
        () => session.validateComment(text),
        throwsA(isA<PttSessionException>()),
      );
    }
    session.dispose();
  });
  test('PTT Big5 symbols keep two cells after UTF-8 negotiation', () {
    for (final rune in '─│●★□…ˇ←→'.runes) {
      expect(
        TerminalScreen.runeWidth(rune),
        2,
        reason: String.fromCharCode(rune),
      );
    }
    final screen = TerminalScreen()..add('● 101 □ 中文…');
    expect(screen.cells[0][1].text, '');
    expect(screen.cells[0][3].text, '1');
    expect(screen.cells[0][7].text, '□');
    expect(screen.cells[0][8].text, '');
    expect(screen.text.split('\n').first, '● 101 □ 中文…');
    screen.add('\x1b[1;11H更新\x1b[K');
    expect(screen.text.split('\n').first, '● 101 □ 更新');
  });
}
