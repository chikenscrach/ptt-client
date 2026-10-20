import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart3_big5/big5.dart';
import 'package:flutter/foundation.dart';
import '../models/ptt_models.dart';
import 'native_http.dart';
import 'terminal.dart';

enum SessionStatus {
  disconnected,
  connecting,
  connected,
  authenticating,
  loggedIn,
}

class PttSessionException implements Exception {
  const PttSessionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PttSession extends ChangeNotifier {
  PttSession({
    Future<WebSocket> Function()? connector,
    this.responseTimeout = const Duration(seconds: 12),
  }) : _connector = connector {
    screen = TerminalScreen(reply: _send);
    _resetCodecs();
  }
  static final endpoint = Uri.parse('wss://ws.ptt.cc/bbs');
  final Future<WebSocket> Function()? _connector;
  final Duration responseTimeout;
  late TerminalScreen screen;
  late PttWireDecoder _decoder;
  late TelnetDecoder _telnet;
  WebSocket? _socket;
  HttpClient? _http;
  StreamSubscription<dynamic>? _subscription;
  final _updates = StreamController<void>.broadcast(sync: true);
  Timer? _paintTimer;
  int _generation = 0;
  bool _disposed = false, _passwordSent = false;
  bool busy = false;
  SessionStatus status = SessionStatus.disconnected;
  String message = '尚未連線', username = '';

  bool get connected => _socket?.readyState == WebSocket.open;
  bool get loggedIn => status == SessionStatus.loggedIn;
  bool get _mainMenu =>
      screen.text.contains('主功能表') || screen.text.contains('主選單');

  void _resetCodecs() {
    _decoder = PttWireDecoder();
    _telnet = TelnetDecoder((bytes) {
      if (connected) _socket!.add(bytes);
    });
  }

  Future<void> connect() async {
    if (connected || status == SessionStatus.connecting) return;
    await disconnect();
    final generation = ++_generation;
    status = SessionStatus.connecting;
    message = '正在建立 PTT 加密連線…';
    screen.clear();
    _resetCodecs();
    _emit();
    final client = nativeHttpClient();
    _http = client;
    try {
      final socket =
          await (_connector?.call() ??
                  WebSocket.connect(
                    endpoint.toString(),
                    headers: {'Origin': 'https://term.ptt.cc'},
                    customClient: client,
                  ))
              .timeout(const Duration(seconds: 18));
      if (_disposed || generation != _generation) {
        await socket.close();
        client.close(force: true);
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 40);
      status = SessionStatus.connected;
      message = '已加密連線，請登入';
      _subscription = socket.listen(
        (dynamic data) {
          if (generation != _generation) return;
          final bytes = data is String
              ? utf8.encode(data)
              : List<int>.from(data as List);
          screen.add(_decoder.add(_telnet.add(bytes)));
          if (_passwordSent && _mainMenu) {
            status = SessionStatus.loggedIn;
            message = '已登入 $username';
          }
          _updates.add(null);
          _paintTimer ??= Timer(const Duration(milliseconds: 45), () {
            _paintTimer = null;
            _emit();
          });
        },
        onError: (Object error) {
          if (generation == _generation) _lost('PTT 連線中斷，請重新連線。');
        },
        onDone: () {
          if (generation == _generation) _lost('已與 PTT 中斷連線。');
        },
      );
      _emit();
    } catch (_) {
      if (generation == _generation) {
        status = SessionStatus.disconnected;
        message = '無法連線 PTT，請檢查網路後重試。';
        client.close(force: true);
        _emit();
        throw PttSessionException(message);
      }
    }
  }

  void _lost(String reason) {
    _socket = null;
    _http?.close(force: true);
    _http = null;
    _passwordSent = false;
    status = SessionStatus.disconnected;
    message = reason;
    _updates.add(null);
    _emit();
  }

  Future<void> disconnect() async {
    ++_generation;
    _paintTimer?.cancel();
    _paintTimer = null;
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    if (socket != null) {
      unawaited(socket.close());
    }
    _http?.close(force: true);
    _http = null;
    _passwordSent = false;
    status = SessionStatus.disconnected;
    message = '尚未連線';
    if (!_updates.isClosed) _updates.add(null);
    _emit();
  }

  void _send(String text) {
    if (!connected) throw const PttSessionException('請先連線 PTT。');
    _socket!.add(utf8.encode(text));
  }

  void sendKey(String text) {
    if (busy) return;
    _send(text);
  }

  Future<void> _wait(bool Function() predicate, {Duration? timeout}) async {
    if (predicate()) return;
    final completer = Completer<void>();
    late StreamSubscription<void> sub;
    sub = _updates.stream.listen((_) {
      if (completer.isCompleted) return;
      if (!connected) {
        completer.completeError(const PttSessionException('連線中斷；操作不會自動重送。'));
      } else if (predicate()) {
        completer.complete();
      }
    });
    try {
      if (predicate() && !completer.isCompleted) completer.complete();
      await completer.future.timeout(
        timeout ?? responseTimeout,
        onTimeout: () {
          throw const PttSessionException('等待 PTT 回應逾時，請查看「PTT 連線」中的畫面。');
        },
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (busy) throw const PttSessionException('上一個 PTT 操作仍在進行中。');
    busy = true;
    _emit();
    try {
      return await action();
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> login(String user, String password) => _exclusive(() async {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]{1,11}$').hasMatch(user)) {
      throw const PttSessionException('請輸入 2～12 碼英數字帳號。');
    }
    if (password.isEmpty || password.runes.any((r) => r < 32 || r > 126)) {
      throw const PttSessionException('密碼須為非空白的可列印英數符號。');
    }
    if (!connected) await connect();
    username = user;
    await _wait(() => RegExp(r'請輸入代號|請輸入您的代號').hasMatch(screen.bottomText));
    _decoder.useUtf8();
    status = SessionStatus.authenticating;
    message = '正在登入…';
    _emit();
    // PTT negotiates UTF-8 when a comma follows the user ID.
    _send('$user,\r');
    await _wait(
      () => RegExp(
        r'密碼[:：]|密碼\s*[:：]|Password',
        caseSensitive: false,
      ).hasMatch(screen.bottomText),
    );
    _passwordSent = true;
    _send('$password\r');
    var transitions = 0;
    while (transitions++ < 8) {
      await _wait(
        () =>
            _mainMenu ||
            RegExp(
              r'密碼不對|密碼錯誤|無此使用者|登入太頻繁|請按任意鍵|按任意鍵|重複登入|刪除其他|您想刪除|驗證碼|驗證器|OTP|2FA',
              caseSensitive: false,
            ).hasMatch(screen.bottomText),
      );
      if (_mainMenu) {
        status = SessionStatus.loggedIn;
        message = '已登入 $user';
        _emit();
        return;
      }
      if (RegExp(r'密碼不對|密碼錯誤|無此使用者|登入太頻繁').hasMatch(screen.bottomText)) {
        _passwordSent = false;
        status = SessionStatus.connected;
        throw const PttSessionException('登入未成功，請檢查帳密及終端畫面的提示。');
      }
      if (RegExp(
        r'重複登入|刪除其他|您想刪除|驗證碼|驗證器|OTP|2FA',
        caseSensitive: false,
      ).hasMatch(screen.bottomText)) {
        status = SessionStatus.connected;
        message = '請在終端畫面完成額外的登入提示；完成後會辨識登入狀態。';
        _emit();
        return;
      }
      // Clear the already matched prompt before waiting for a fresh screen.
      screen.clear();
      _send(' ');
    }
    status = SessionStatus.connected;
    message = '請在終端畫面繼續完成登入。';
    _emit();
  });

  Future<void> openArticle(ArticleSummary article) =>
      _exclusive(() => _navigate(article));

  Future<void> _navigate(ArticleSummary article) async {
    if (!loggedIn) throw const PttSessionException('請先登入 PTT。');
    if (!isBoardName(article.board) || article.aid == null) {
      throw const PttSessionException('無效的文章代碼。');
    }
    // Never blindly send navigation keys into an editor or confirmation dialog.
    if (!_mainMenu &&
        !RegExp(
          r'文章選讀|文章瀏覽|瀏覽 第|目前顯示|看板《|看板\s+《|我的最愛|看板列表',
        ).hasMatch(screen.text)) {
      throw const PttSessionException('請先在「PTT 連線」返回主功能表，再進行文章操作。');
    }
    for (var i = 0; i < 6 && !_mainMenu; i++) {
      screen.clear();
      _send('\x1b[D');
      await _wait(() => screen.text.trim().isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!_mainMenu) throw const PttSessionException('無法返回主功能表，請改用終端操作。');
    screen.clear();
    _send('s');
    await _wait(() => RegExp(r'看板|名稱').hasMatch(screen.bottomText));
    screen.clear();
    _send('${article.board}\r');
    await _wait(() => screen.text.contains(article.board));
    if (RegExp(r'按任意鍵').hasMatch(screen.bottomText)) {
      screen.clear();
      _send(' ');
      await _wait(() => screen.text.contains(article.board));
    }
    if (!RegExp(r'文章選讀|選讀|看板《|看板\s+《').hasMatch(screen.text)) {
      throw const PttSessionException('尚未進入文章列表，請查看終端畫面的看板提示。');
    }
    screen.clear();
    _send('${article.aid}\r');
    await _wait(() => RegExp(r'文章選讀|選讀|不存在|找不到').hasMatch(screen.text));
    if (RegExp(r'不存在|找不到').hasMatch(screen.bottomText)) {
      throw const PttSessionException('PTT 找不到此文章。');
    }
    // Query the selected article's actual AID. A failed search can leave the
    // cursor on another article with an identical title prefix.
    screen.clear();
    _send('Q');
    await _wait(
      () => screen.text.contains('再按') || screen.bottomText.contains('任意鍵'),
    );
    final identity = RegExp(
      '${RegExp.escape(article.aid!)}\\s+\\(${RegExp.escape(article.board)}\\)',
    );
    if (!identity.hasMatch(screen.text)) {
      throw const PttSessionException('站方回傳的文章代碼與目標不符，已停止操作；尚未送出推文。');
    }
    screen.clear();
    _send(' ');
    await _wait(() => RegExp(r'文章選讀|選讀').hasMatch(screen.text));
    screen.clear();
    _send('\r');
    await _wait(() => RegExp(r'文章瀏覽|瀏覽 第|目前顯示|作者\s').hasMatch(screen.text));
    // Confirm the selected article's board and title before any write action.
    if (!screen.text.contains(article.board) ||
        !screen.text.contains(
          article.title.substring(0, article.title.length.clamp(0, 12)),
        )) {
      throw const PttSessionException('無法確認目前文章，請在終端畫面檢查；尚未送出推文。');
    }
  }

  // Also fits boards with logged IP addresses and padded user IDs.
  int get commentByteLimit => 34;

  void validateComment(String content) {
    if (content.trim().isEmpty ||
        content.runes.any((r) => r < 32 || r == 127)) {
      throw const PttSessionException('推文請使用單行文字，不能包含控制字元。');
    }
    try {
      final encoded = Big5.encode(content);
      if (Big5.decode(encoded) != content) {
        throw const PttSessionException('推文含有 PTT 無法表示的字元，請移除表情符號或罕見字。');
      }
      if (encoded.length > commentByteLimit) {
        throw PttSessionException(
          '推文過長：此帳號先以 $commentByteLimit 個 Big5 位元組為上限（中文字通常佔 2）。',
        );
      }
    } on PttSessionException {
      rethrow;
    } catch (_) {
      throw const PttSessionException('推文含有 PTT 無法表示的字元。');
    }
  }

  Future<void> postComment(
    ArticleSummary article,
    int kind,
    String content,
  ) => _exclusive(() async {
    validateComment(content);
    if (kind < 1 || kind > 3) throw const PttSessionException('無效的推文種類。');
    await _navigate(article);
    screen.clear();
    _send('X');
    await _wait(
      () => RegExp(r'您覺得這篇文章|推文|發言|禁止|不足').hasMatch(screen.bottomText),
    );
    if (!screen.bottomText.contains('您覺得這篇文章')) {
      throw const PttSessionException('PTT 未開放此篇推文，請查看終端提示。');
    }
    if (kind == 2 && !screen.bottomText.contains('2.')) {
      throw const PttSessionException('此看板不開放噓文。');
    }
    screen.clear();
    _send('$kind');
    await _wait(
      () =>
          screen.bottomText.contains('$username:') ||
          screen.bottomText.contains('$username :'),
    );
    screen.clear();
    _send('$content\r');
    await _wait(
      () => RegExp(
        r'確定\s*\[y/N\]',
        caseSensitive: false,
      ).hasMatch(screen.bottomText),
    );
    if (!screen.bottomText.contains(content)) {
      _send('n\r');
      throw const PttSessionException('PTT 回顯與輸入不符，已取消送出。');
    }
    screen.clear();
    _send('y\r');
    try {
      await _wait(
        () => RegExp(r'文章瀏覽|瀏覽 第|目前顯示|寫入失敗|無法寫入').hasMatch(screen.text),
      );
      if (RegExp(r'寫入失敗|無法寫入').hasMatch(screen.text)) {
        throw const PttSessionException('PTT 回報寫入失敗。');
      }
      message = '推文操作已完成，請重新整理文章確認結果。';
      _emit();
    } catch (_) {
      // A timeout after the final confirmation is an unknown outcome, never retry.
      throw const PttSessionException('尚無法確認推文結果，請先重新整理文章；請勿直接重送。');
    }
  });

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect().whenComplete(() => _updates.close()));
    super.dispose();
  }
}
