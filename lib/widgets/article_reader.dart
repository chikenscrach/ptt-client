import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_model.dart';
import '../models/ptt_models.dart';
import 'link_card.dart';

class ArticleReader extends StatefulWidget {
  const ArticleReader({
    super.key,
    required this.article,
    required this.model,
    required this.onOpen,
    required this.onLogin,
  });
  final PttArticle article;
  final AppModel model;
  final ValueChanged<Uri> onOpen;
  final VoidCallback onLogin;
  @override
  State<ArticleReader> createState() => _ArticleReaderState();
}

class _ArticleReaderState extends State<ArticleReader> {
  late List<ArticleBlock> _blocks;
  final _scroll = ScrollController();
  Timer? _saveTimer;
  String get _scrollKey => 'scroll:${widget.article.summary.url.path}';

  @override
  void initState() {
    super.initState();
    _blocks = articleBlocks(widget.article.body);
    _scroll.addListener(_rememberScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final offset = widget.model.prefs.getDouble(_scrollKey) ?? 0;
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void didUpdateWidget(covariant ArticleReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article != widget.article) {
      _blocks = articleBlocks(widget.article.body);
    }
  }

  void _rememberScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      if (_scroll.hasClients) {
        unawaited(widget.model.prefs.setDouble(_scrollKey, _scroll.offset));
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    final summary = article.summary;
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${summary.board}  /  文章',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新整理文章',
                onPressed: widget.model.loadingArticle
                    ? null
                    : () => _refresh(context),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '複製文章網址',
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: summary.url.toString()),
                  );
                  _message(context, '已複製文章網址');
                },
                icon: const Icon(Icons.link),
              ),
              IconButton(
                tooltip: '在 App 內開啟原文',
                onPressed: () => widget.onOpen(summary.url),
                icon: const Icon(Icons.open_in_new),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (widget.model.loadingArticle)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            child: ListView.builder(
              key: PageStorageKey(summary.url.toString()),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
              itemCount: _blocks.length + article.comments.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 26),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.title,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            Text(
                              summary.author,
                              style: TextStyle(
                                color: colors.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              article.postedAt.isEmpty
                                  ? summary.date
                                  : article.postedAt,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                            if (summary.aid != null)
                              Text(
                                summary.aid!,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                }
                if (index <= _blocks.length) {
                  final block = _blocks[index - 1];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SelectableText(
                          block.text,
                          style: TextStyle(
                            fontSize: widget.model.fontSize,
                            height: 1.75,
                            fontFamilyFallback: const [
                              'Microsoft JhengHei',
                              'Noto Sans CJK TC',
                            ],
                          ),
                        ),
                        for (final url in block.urls)
                          LinkCard(
                            key: ValueKey(url),
                            url: url,
                            model: widget.model,
                            onOpen: widget.onOpen,
                          ),
                      ],
                    ),
                  );
                }
                if (index == _blocks.length + 1) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.forum_outlined, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          '推文  ${article.comments.length}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  );
                }
                final comment = article.comments[index - _blocks.length - 2];
                final color = comment.tag == '推'
                    ? const Color(0xff55cfa5)
                    : comment.tag == '噓'
                    ? const Color(0xffed8e95)
                    : colors.onSurfaceVariant;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${comment.tag} ',
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(
                              text: '${comment.author}：',
                              style: TextStyle(color: colors.primary),
                            ),
                            TextSpan(text: comment.content),
                          ],
                        ),
                        style: TextStyle(
                          fontSize: widget.model.fontSize - 1,
                          height: 1.6,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          comment.time,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      for (final url in extractUrls(comment.content))
                        LinkCard(
                          key: ValueKey(url),
                          url: url,
                          model: widget.model,
                          onOpen: widget.onOpen,
                        ),
                      const Divider(height: 12),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.model.session.loggedIn
                        ? '以 ${widget.model.session.username} 發言'
                        : '登入後可推噓文',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: widget.model.session.busy
                      ? null
                      : () => _compose(context),
                  icon: const Icon(Icons.mode_comment_outlined, size: 18),
                  label: const Text('推噓文'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _refresh(BuildContext context) async {
    try {
      await widget.model.openArticle(widget.article.summary, refresh: true);
    } catch (error) {
      if (context.mounted) _message(context, error.toString());
    }
    if (context.mounted && widget.model.articleError != null) {
      _message(context, widget.model.articleError!);
    }
  }

  Future<void> _compose(BuildContext context) async {
    if (!widget.model.session.loggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('請先在「PTT 連線」登入帳號。'),
          action: SnackBarAction(label: '前往登入', onPressed: widget.onLogin),
        ),
      );
      return;
    }
    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _CommentDialog(model: widget.model, summary: widget.article.summary),
    );
    if (sent == true && context.mounted) {
      _message(context, '推文操作完成，正在更新文章。');
      await _refresh(context);
    }
  }

  void _message(BuildContext context, String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
}

class _CommentDialog extends StatefulWidget {
  const _CommentDialog({required this.model, required this.summary});
  final AppModel model;
  final ArticleSummary summary;
  @override
  State<_CommentDialog> createState() => _CommentDialogState();
}

class _CommentDialogState extends State<_CommentDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.model.draft(widget.summary),
  );
  int _kind = 1;
  bool _sending = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_sending,
    child: AlertDialog(
      title: const Text('推噓文'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.summary.board}・${widget.summary.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('推')),
                ButtonSegment(value: 2, label: Text('噓')),
                ButtonSegment(value: 3, label: Text('→')),
              ],
              selected: {_kind},
              onSelectionChanged: _sending
                  ? null
                  : (value) => setState(() => _kind = value.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              autofocus: true,
              enabled: !_sending,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '推文內容',
                hintText: '請輸入單行文字',
              ),
              onChanged: (value) =>
                  widget.model.saveDraft(widget.summary, value),
            ),
            Text(
              '以 ${widget.model.session.username} 發言。草稿保留在本機。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_sending)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context, false),
          child: const Text('稍後再說'),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: const Text('送出'),
        ),
      ],
    ),
  );

  Future<void> _send() async {
    final content = _text.text.trim();
    try {
      widget.model.session.validateComment(content);
    } catch (error) {
      setState(() => _error = error.toString());
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.model.saveDraft(widget.summary, content);
      await widget.model.session.postComment(widget.summary, _kind, content);
      await widget.model.saveDraft(widget.summary, '');
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}
