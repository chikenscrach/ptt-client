import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'app_model.dart';
import 'models/ptt_models.dart';
import 'pages/terminal_page.dart';
import 'services/ptt_web.dart';
import 'widgets/article_reader.dart';
import 'widgets/web_preview.dart';

class PttClientApp extends StatelessWidget {
  const PttClientApp({super.key, required this.model, this.loadOnStart = true});
  final AppModel model;
  final bool loadOnStart;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: model,
    builder: (context, _) => MaterialApp(
      title: 'PTT Client',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: model.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: _Shell(model: model, loadOnStart: loadOnStart),
    ),
  );

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff287e6f),
      brightness: brightness,
      primary: dark ? const Color(0xff75debe) : const Color(0xff196957),
      surface: dark ? const Color(0xff101a20) : const Color(0xfff7f9f8),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      fontFamilyFallback: const ['Microsoft JhengHei', 'Noto Sans CJK TC'],
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xff1a2931) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: 0.45),
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell({required this.model, required this.loadOnStart});
  final AppModel model;
  final bool loadOnStart;
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> with WidgetsBindingObserver {
  int _tab = 0;
  Uri? _preview;
  final _search = TextEditingController();
  AppModel get model => widget.model;
  bool get _wide => MediaQuery.sizeOf(context).width >= 1100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.loadOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(() => model.loadBoard(model.selectedBoard));
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && model.session.connected) {
      // Dart's WebSocket ping/pong detects a socket lost while Android was asleep.
      // Reading state and drafts are kept; credentials and writes are never replayed.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on AgeConfirmationRequired {
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('年齡確認'),
          content: const Text('PTT 要求此看板的讀者已滿 18 歲。您是否已滿 18 歲？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('我已滿 18 歲'),
            ),
          ],
        ),
      );
      if (accepted == true) {
        await model.confirmAge();
        await _run(action);
      }
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _openUrl(Uri url) {
    if (MediaQuery.sizeOf(context).width >= 1450 &&
        _tab == 0 &&
        ModalRoute.of(context)?.isCurrent == true) {
      setState(() => _preview = url);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(url: url, guard: model.previews.guard),
        ),
      );
    }
  }

  void _login() {
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _tab = 1);
  }

  void _openArticle(ArticleSummary summary) {
    _run(() => model.openArticle(summary));
    if (!_wide) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              _ArticlePage(model: model, onOpen: _openUrl, onLogin: _login),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                Icons.forum_rounded,
                color: colors.onPrimary,
                size: 19,
              ),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'PTT Client',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: [
          if (_tab == 0)
            IconButton(
              tooltip: '前往看板',
              onPressed: _searchBoard,
              icon: const Icon(Icons.search),
            ),
          IconButton(
            tooltip: model.session.loggedIn ? 'PTT 已登入' : 'PTT 連線／登入',
            onPressed: _login,
            icon: Icon(
              model.session.loggedIn
                  ? Icons.account_circle
                  : Icons.account_circle_outlined,
              color: model.session.loggedIn ? colors.primary : null,
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      drawer: desktop
          ? null
          : Drawer(child: SafeArea(child: _boardSidebar(closeDrawer: true))),
      body: Row(
        children: [
          if (desktop)
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.view_agenda_outlined),
                  selectedIcon: Icon(Icons.view_agenda),
                  label: Text('看板'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.terminal),
                  label: Text('PTT 連線'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune),
                  label: Text('設定'),
                ),
              ],
            ),
          if (desktop) const VerticalDivider(width: 1),
          Expanded(
            child: switch (_tab) {
              1 => TerminalPage(model: model),
              2 => _settings(),
              _ => Row(
                children: [
                  if (desktop) SizedBox(width: 205, child: _boardSidebar()),
                  if (desktop) const VerticalDivider(width: 1),
                  SizedBox(
                    width: _wide ? 340 : null,
                    child: _wide ? _articleList() : null,
                  ),
                  if (_wide) const VerticalDivider(width: 1),
                  Expanded(child: _wide ? _readerPane() : _articleList()),
                  if (_preview != null &&
                      MediaQuery.sizeOf(context).width >= 1450) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: MediaQuery.sizeOf(context).width >= 1800
                          ? 480
                          : 380,
                      child: WebPreview(
                        key: ValueKey(_preview),
                        url: _preview!,
                        guard: model.previews.guard,
                        onClose: () => setState(() => _preview = null),
                      ),
                    ),
                  ],
                ],
              ),
            },
          ),
        ],
      ),
      bottomNavigationBar: desktop
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.view_agenda_outlined),
                  selectedIcon: Icon(Icons.view_agenda),
                  label: '看板',
                ),
                NavigationDestination(
                  icon: Icon(Icons.terminal),
                  label: 'PTT 連線',
                ),
                NavigationDestination(icon: Icon(Icons.tune), label: '設定'),
              ],
            ),
    );
  }

  Widget _boardSidebar({bool closeDrawer = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 24, 16, 12),
        child: Text(
          '釘選看板',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ),
      Expanded(
        child: ListView(
          children: [
            for (final board in model.boards)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ListTile(
                  dense: true,
                  selected: board.name == model.selectedBoard,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  title: Text(
                    board.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: Text(
                    board.description,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    if (closeDrawer) Navigator.pop(context);
                    setState(() => _tab = 0);
                    _run(() => model.loadBoard(board.name));
                  },
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add, size: 18),
              title: const Text('加入看板', style: TextStyle(fontSize: 13)),
              onTap: () {
                if (closeDrawer) Navigator.pop(context);
                _searchBoard();
              },
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '未登入時讀取公開網頁\n登入後直接由 PTT 連線閱讀',
          style: TextStyle(
            fontSize: 11,
            height: 1.7,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );

  Widget _articleList() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.selectedBoard,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 22,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${model.boardFromSession ? "PTT 連線" : "公開看板"}・${model.articles.length} 篇文章',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '釘選／取消釘選',
              onPressed: () {
                if (model.boards.any((b) => b.name == model.selectedBoard)) {
                  _run(() => model.unpinBoard(model.selectedBoard));
                } else {
                  _run(() => model.pinBoard(model.selectedBoard));
                }
              },
              icon: Icon(
                model.boards.any((b) => b.name == model.selectedBoard)
                    ? Icons.star
                    : Icons.star_border,
                size: 20,
              ),
            ),
            IconButton(
              tooltip: '重新整理看板',
              onPressed: model.loadingBoard
                  ? null
                  : () => _run(() => model.loadBoard(model.selectedBoard)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      if (model.loadingBoard) const LinearProgressIndicator(minHeight: 2),
      const Divider(height: 1),
      Expanded(
        child: model.articles.isEmpty
            ? _empty(
                icon: model.boardError == null
                    ? Icons.forum_outlined
                    : Icons.cloud_off_outlined,
                title: model.loadingBoard
                    ? '正在讀取看板…'
                    : model.boardError == null
                    ? '尚無文章'
                    : '看板暫時無法讀取',
                message: model.boardError ?? '從左側釘選看板或搜尋開始。',
                action: model.loadingBoard
                    ? null
                    : () => _run(() => model.loadBoard(model.selectedBoard)),
              )
            : RefreshIndicator(
                onRefresh: () =>
                    _run(() => model.loadBoard(model.selectedBoard)),
                child: ListView.separated(
                  key: PageStorageKey('board:${model.selectedBoard}'),
                  itemCount: model.articles.length + 1,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 18, endIndent: 18),
                  itemBuilder: (context, index) {
                    if (index == model.articles.length) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            if (model.boardError != null)
                              Text(
                                model.boardError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            if (model.previousPage != null)
                              OutlinedButton(
                                onPressed: model.loadingMore
                                    ? null
                                    : () => _run(
                                        () => model.loadBoard(
                                          model.selectedBoard,
                                          more: true,
                                        ),
                                      ),
                                child: Text(
                                  model.loadingMore ? '載入中…' : '載入更早文章',
                                ),
                              ),
                          ],
                        ),
                      );
                    }
                    final article = model.articles[index];
                    final selected = model.selectedSummary?.url == article.url;
                    final read = model.read.contains(article.url.toString());
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 9,
                      ),
                      selected: selected,
                      leading: SizedBox(
                        width: 30,
                        child: Center(
                          child: article.pinned
                              ? const Icon(Icons.push_pin_outlined, size: 17)
                              : Text(
                                  article.score.isEmpty ? '·' : article.score,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: article.score.startsWith('X')
                                        ? const Color(0xffe48893)
                                        : const Color(0xff58bd98),
                                  ),
                                ),
                        ),
                      ),
                      title: Text(
                        article.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: read
                              ? FontWeight.normal
                              : FontWeight.w600,
                          color: read
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : null,
                          height: 1.5,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${article.author}  ·  ${article.date}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      onTap: () => _openArticle(article),
                    );
                  },
                ),
              ),
      ),
    ],
  );

  Widget _readerPane() {
    if (model.article != null) {
      return ArticleReader(
        key: ValueKey(model.article!.summary.url),
        article: model.article!,
        model: model,
        onOpen: _openUrl,
        onLogin: _login,
      );
    }
    return _empty(
      icon: Icons.chrome_reader_mode_outlined,
      title: model.loadingArticle
          ? '正在載入文章…'
          : model.articleError != null
          ? '無法讀取文章'
          : '選一篇，開始閱讀',
      message: model.articleError ?? '文章中的連結可直接預覽，點擊即可在 App 內瀏覽。',
      action: model.articleError != null && model.selectedSummary != null
          ? () => _run(() => model.openArticle(model.selectedSummary!))
          : null,
    );
  }

  Widget _settings() => Align(
    alignment: Alignment.topCenter,
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '閱讀與預覽',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 24),
        ),
        const SizedBox(height: 24),
        SwitchListTile(
          title: const Text('深色模式'),
          value: model.darkMode,
          onChanged: (value) => _run(() => model.setDark(value)),
        ),
        ListTile(
          title: const Text('文章字級'),
          subtitle: Slider(
            min: 14,
            max: 24,
            divisions: 10,
            value: model.fontSize,
            label: '${model.fontSize.toInt()}',
            onChanged: (value) => _run(() => model.setFont(value)),
          ),
        ),
        const Divider(),
        const ListTile(
          title: Text('連結預覽載入方式'),
          subtitle: Text('設定套用於之後載入的預覽；完整網頁在點擊後才載入。'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<PreviewPolicy>(
            isExpanded: true,
            initialValue: model.policy,
            items: const [
              DropdownMenuItem(
                value: PreviewPolicy.manual,
                child: Text('點擊才載入'),
              ),
              DropdownMenuItem(
                value: PreviewPolicy.wifi,
                child: Text('Wi-Fi／有線網路自動載入'),
              ),
              DropdownMenuItem(
                value: PreviewPolicy.always,
                child: Text('所有網路自動載入'),
              ),
            ],
            onChanged: (value) {
              if (value != null) _run(() => model.setPolicy(value));
            },
          ),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const ListTile(
          title: Text('關於 PTT Client'),
          subtitle: Text('0.1.2・Windows / Android\n獨立第三方客戶端，非 PTT 官方產品。'),
        ),
        ListTile(
          title: const Text('專案與使用說明'),
          subtitle: const Text('github.com/chikenscrach/ptt-client'),
          trailing: const Icon(Icons.open_in_new),
          onTap: () =>
              _openUrl(Uri.parse('https://github.com/chikenscrach/ptt-client')),
        ),
        ListTile(
          title: const Text('開源授權'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'PTT Client',
            applicationVersion: '0.1.2',
          ),
        ),
      ],
    ),
  );

  Future<void> _searchBoard() async {
    _search.clear();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('前往看板'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: _search,
            autofocus: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '看板英文名稱',
              hintText: '例如 C_Chat、PC_Shopping',
            ),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _search.text.trim()),
            child: const Text('前往'),
          ),
        ],
      ),
    );
    if (!mounted || name == null || name.isEmpty) return;
    setState(() => _tab = 0);
    await _run(() => model.loadBoard(name));
  }

  Widget _empty({
    required IconData icon,
    required String title,
    required String message,
    VoidCallback? action,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, height: 1.7),
          ),
          if (action != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: OutlinedButton(onPressed: action, child: const Text('重試')),
            ),
        ],
      ),
    ),
  );
}

class _ArticlePage extends StatelessWidget {
  const _ArticlePage({
    required this.model,
    required this.onOpen,
    required this.onLogin,
  });
  final AppModel model;
  final ValueChanged<Uri> onOpen;
  final VoidCallback onLogin;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: model,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(model.selectedSummary?.board ?? '文章')),
      body: model.article != null
          ? ArticleReader(
              key: ValueKey(model.article!.summary.url),
              article: model.article!,
              model: model,
              onOpen: onOpen,
              onLogin: onLogin,
            )
          : Center(
              child: model.loadingArticle
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(model.articleError ?? '無法讀取文章'),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: model.selectedSummary == null
                                ? null
                                : () async {
                                    try {
                                      await model.openArticle(
                                        model.selectedSummary!,
                                      );
                                    } catch (_) {}
                                  },
                            child: const Text('重試'),
                          ),
                        ],
                      ),
                    ),
            ),
    ),
  );
}
