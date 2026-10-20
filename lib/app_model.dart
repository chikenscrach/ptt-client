import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/ptt_models.dart';
import 'services/link_preview.dart';
import 'services/ptt_session.dart';
import 'services/ptt_web.dart';

enum PreviewPolicy { manual, wifi, always }

class AppModel extends ChangeNotifier {
  AppModel(
    this.prefs, {
    PttWeb? web,
    LinkPreviewService? previews,
    PttSession? session,
  }) : web = web ?? PttWeb(),
       previews = previews ?? LinkPreviewService(),
       session = session ?? PttSession() {
    darkMode = prefs.getBool('darkMode') ?? true;
    fontSize = prefs.getDouble('fontSize') ?? 17;
    policy =
        PreviewPolicy.values[(prefs.getInt('previewPolicy') ?? 1).clamp(0, 2)];
    boards =
        (prefs.getStringList('boards') ??
                defaultBoards.map((b) => b.name).toList())
            .where(isBoardName)
            .map(
              (name) => Board(
                name,
                defaultBoards
                        .where((b) => b.name == name)
                        .firstOrNull
                        ?.description ??
                    '自訂看板',
              ),
            )
            .toList();
    read = (prefs.getStringList('read') ?? []).toSet();
    username = prefs.getString('username') ?? '';
    selectedBoard = boards.firstOrNull?.name ?? 'C_Chat';
    this.web.over18 = prefs.getBool('over18') ?? false;
    _sessionWasLoggedIn = this.session.loggedIn;
    this.session.addListener(_sessionChanged);
  }

  final SharedPreferences prefs;
  final PttWeb web;
  final LinkPreviewService previews;
  final PttSession session;
  late List<Board> boards;
  late Set<String> read;
  late bool darkMode;
  late double fontSize;
  late PreviewPolicy policy;
  late String selectedBoard, username;
  List<ArticleSummary> articles = [];
  PttArticle? article;
  ArticleSummary? selectedSummary;
  Uri? previousPage;
  bool loadingBoard = false, loadingArticle = false, loadingMore = false;
  bool boardFromSession = false;
  String? boardError, articleError;
  int _boardRequest = 0, _articleRequest = 0;
  bool _disposed = false;
  DateTime? _connectivityChecked;
  bool _unmetered = false;
  bool _sessionWasLoggedIn = false, _reloadAfterLogin = false;

  void _sessionChanged() {
    if (_disposed) return;
    final loggedIn = session.loggedIn;
    if (loggedIn && !_sessionWasLoggedIn) _reloadAfterLogin = true;
    if (!loggedIn) _reloadAfterLogin = false;
    _sessionWasLoggedIn = loggedIn;
    if (_reloadAfterLogin && !session.busy) {
      _reloadAfterLogin = false;
      scheduleMicrotask(() {
        if (!_disposed && session.loggedIn) {
          // loadBoard records errors for the reader; an automatic reload cannot
          // display the age-confirmation dialog used by explicit UI actions.
          unawaited(loadBoard(selectedBoard).catchError((Object _) {}));
        }
      });
    }
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadBoard(String name, {bool more = false}) async {
    if (!isBoardName(name)) {
      boardError = '看板名稱格式不正確。';
      _changed();
      return;
    }
    if (more &&
        (loadingMore || previousPage == null || name != selectedBoard)) {
      return;
    }
    final request = more ? _boardRequest : ++_boardRequest;
    final page = more ? previousPage : null;
    final useSession = more ? page!.scheme == 'ptt-bbs' : session.loggedIn;
    if (more) {
      loadingMore = true;
    } else {
      selectedBoard = name;
      articles = [];
      previousPage = null;
      selectedSummary = null;
      article = null;
      articleError = null;
      ++_articleRequest;
      loadingArticle = false;
      loadingBoard = true;
      loadingMore = false;
      boardFromSession = useSession;
    }
    boardError = null;
    _changed();
    try {
      final result = useSession
          ? await session.readBoard(name, page: page)
          : await web.board(name, page: page);
      if (request != _boardRequest || _disposed) return;
      final known = articles.map((a) => a.url.toString()).toSet();
      articles = [
        ...articles,
        ...result.articles.where((a) => known.add(a.url.toString())),
      ];
      previousPage = result.previousPage;
    } catch (error) {
      if (request == _boardRequest && !_disposed) boardError = error.toString();
      if (error is AgeConfirmationRequired) rethrow;
    } finally {
      if (request == _boardRequest && !_disposed) {
        loadingBoard = false;
        loadingMore = false;
        _changed();
      }
    }
  }

  Future<void> openArticle(
    ArticleSummary summary, {
    bool refresh = false,
  }) async {
    final request = ++_articleRequest;
    selectedSummary = summary;
    if (!refresh) article = null;
    loadingArticle = true;
    articleError = null;
    _changed();
    try {
      final result = session.loggedIn || summary.fromBbs
          ? await session.readArticle(summary)
          : await web.article(summary);
      if (request != _articleRequest || _disposed) return;
      article = result;
      selectedSummary = result.summary;
      articles = articles
          .map((a) => a.url == summary.url ? result.summary : a)
          .toList();
      read.remove(summary.url.toString());
      read.add(result.summary.url.toString());
      if (summary.fromBbs) read.add(summary.url.toString());
      while (read.length > 500) {
        read.remove(read.first);
      }
      await prefs.setStringList('read', read.toList());
    } catch (error) {
      if (request == _articleRequest && !_disposed) {
        articleError = error.toString();
      }
      if (error is AgeConfirmationRequired) rethrow;
    } finally {
      if (request == _articleRequest && !_disposed) {
        loadingArticle = false;
        _changed();
      }
    }
  }

  Future<void> confirmAge() async {
    web.over18 = true;
    await prefs.setBool('over18', true);
  }

  Future<void> rememberUsername(String value) async {
    username = value;
    await prefs.setString('username', value);
    _changed();
  }

  Future<void> setDark(bool value) async {
    darkMode = value;
    _changed();
    await prefs.setBool('darkMode', value);
  }

  Future<void> setFont(double value) async {
    fontSize = value;
    _changed();
    await prefs.setDouble('fontSize', value);
  }

  Future<void> setPolicy(PreviewPolicy value) async {
    policy = value;
    _changed();
    await prefs.setInt('previewPolicy', value.index);
  }

  Future<void> pinBoard(String name) async {
    if (!isBoardName(name) ||
        boards.any((b) => b.name.toLowerCase() == name.toLowerCase())) {
      return;
    }
    boards = [...boards, Board(name, '自訂看板')];
    _changed();
    await prefs.setStringList('boards', boards.map((b) => b.name).toList());
  }

  Future<void> unpinBoard(String name) async {
    boards = boards.where((b) => b.name != name).toList();
    _changed();
    await prefs.setStringList('boards', boards.map((b) => b.name).toList());
  }

  Future<bool> autoPreview() async {
    if (policy == PreviewPolicy.manual) return false;
    if (policy == PreviewPolicy.always) return true;
    if (_connectivityChecked == null ||
        DateTime.now().difference(_connectivityChecked!) >
            const Duration(seconds: 15)) {
      try {
        final values = await Connectivity().checkConnectivity();
        _unmetered =
            values.contains(ConnectivityResult.wifi) ||
            values.contains(ConnectivityResult.ethernet);
      } catch (_) {
        _unmetered = false;
      }
      _connectivityChecked = DateTime.now();
    }
    return _unmetered;
  }

  String draft(ArticleSummary summary) =>
      prefs.getString('draft:${summary.url.path}') ?? '';
  Future<void> saveDraft(ArticleSummary summary, String value) async {
    if (value.isEmpty) {
      await prefs.remove('draft:${summary.url.path}');
    } else {
      await prefs.setString('draft:${summary.url.path}', value);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_sessionChanged);
    session.dispose();
    web.close();
    previews.close();
    super.dispose();
  }
}
