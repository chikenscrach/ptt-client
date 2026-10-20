import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/link_preview.dart';

class WebPreview extends StatefulWidget {
  const WebPreview({
    super.key,
    required this.url,
    required this.guard,
    this.onClose,
  });
  final Uri url;
  final UrlGuard guard;
  final VoidCallback? onClose;
  @override
  State<WebPreview> createState() => _WebPreviewState();
}

class _WebPreviewState extends State<WebPreview> {
  InAppWebViewController? _controller;
  late Uri _current;
  late Future<void> _permission;
  String? _error;
  double _progress = 0;
  bool _back = false;

  @override
  void initState() {
    super.initState();
    _current = widget.url;
    _permission = widget.guard.check(widget.url);
  }

  Future<void> _external() async {
    if (!UrlGuard.isWebUrl(_current)) return;
    try {
      final opened = await launchUrl(
        _current,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) _showMessage('無法開啟外部瀏覽器，請複製網址。');
    } catch (_) {
      if (mounted) _showMessage('無法開啟外部瀏覽器，請複製網址。');
    }
  }

  void _showMessage(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<NavigationActionPolicy> _navigation(NavigationAction action) async {
    final value = action.request.url?.toString();
    if (value == 'about:blank') return NavigationActionPolicy.ALLOW;
    final uri = Uri.tryParse(value ?? '');
    try {
      if (uri == null) return NavigationActionPolicy.CANCEL;
      await widget.guard.check(uri);
      return NavigationActionPolicy.ALLOW;
    } catch (_) {
      if (mounted) _showMessage('已停止開啟非公開網頁或外部應用連結。');
      return NavigationActionPolicy.CANCEL;
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: '上一頁',
                onPressed: _back ? () => _controller?.goBack() : null,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Tooltip(
                  message: _current.toString(),
                  child: Text(
                    _current.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                tooltip: '重新整理',
                onPressed: () => _controller?.reload(),
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                tooltip: '網頁選項',
                onSelected: (value) {
                  if (value == 'external') _external();
                  if (value == 'copy') {
                    Clipboard.setData(ClipboardData(text: _current.toString()));
                    _showMessage('已複製網址');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'copy', child: Text('複製網址')),
                  PopupMenuItem(value: 'external', child: Text('用外部瀏覽器開啟')),
                ],
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: '關閉預覽',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        if (_progress > 0 && _progress < 1)
          LinearProgressIndicator(value: _progress, minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(onPressed: _external, child: const Text('外部開啟')),
            ],
          ),
        Expanded(
          child: FutureBuilder<void>(
            future: _permission,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(snapshot.error.toString()),
                  ),
                );
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              return InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.url.toString()),
                ),
                initialSettings: InAppWebViewSettings(
                  useShouldOverrideUrlLoading: true,
                  javaScriptEnabled: true,
                  mediaPlaybackRequiresUserGesture: true,
                  allowFileAccess: false,
                  allowContentAccess: false,
                  supportMultipleWindows: true,
                  javaScriptCanOpenWindowsAutomatically: false,
                ),
                onWebViewCreated: (controller) => _controller = controller,
                shouldOverrideUrlLoading: (_, action) => _navigation(action),
                onProgressChanged: (_, progress) {
                  if (mounted) setState(() => _progress = progress / 100);
                },
                onLoadStart: (_, url) {
                  if (mounted) {
                    setState(() {
                      _error = null;
                      _current =
                          Uri.tryParse(url?.toString() ?? '') ?? _current;
                    });
                  }
                },
                onLoadStop: (controller, url) async {
                  final canBack = await controller.canGoBack();
                  if (mounted) {
                    setState(() {
                      _back = canBack;
                      _progress = 1;
                    });
                  }
                },
                onReceivedError: (_, request, error) {
                  if (request.isForMainFrame == true && mounted) {
                    setState(() => _error = '網頁載入失敗，可重試或改用外部瀏覽器。');
                  }
                },
                onCreateWindow: (controller, action) async {
                  final uri = Uri.tryParse(
                    action.request.url?.toString() ?? '',
                  );
                  if (uri != null) {
                    try {
                      await widget.guard.check(uri);
                      await controller.loadUrl(
                        urlRequest: URLRequest(url: WebUri(uri.toString())),
                      );
                    } catch (_) {
                      if (mounted) _showMessage('此連結無法在預覽中開啟。');
                    }
                  }
                  return false;
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

class BrowserPage extends StatelessWidget {
  const BrowserPage({super.key, required this.url, required this.guard});
  final Uri url;
  final UrlGuard guard;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: WebPreview(
        url: url,
        guard: guard,
        onClose: () => Navigator.pop(context),
      ),
    ),
  );
}
