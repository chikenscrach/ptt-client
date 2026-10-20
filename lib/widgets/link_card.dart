import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../app_model.dart';
import '../services/link_preview.dart';

class LinkCard extends StatefulWidget {
  const LinkCard({
    super.key,
    required this.url,
    required this.model,
    required this.onOpen,
  });
  final Uri url;
  final AppModel model;
  final ValueChanged<Uri> onOpen;
  @override
  State<LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<LinkCard> {
  Future<LinkPreview?>? _future;
  @override
  void initState() {
    super.initState();
    _autoLoad();
  }

  @override
  void didUpdateWidget(covariant LinkCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = null;
      _autoLoad();
    }
  }

  Future<void> _autoLoad() async {
    final url = widget.url;
    if (await widget.model.autoPreview() &&
        mounted &&
        url == widget.url &&
        _future == null) {
      _load();
    }
  }

  void _load() {
    final request = widget.model.previews
        .preview(widget.url)
        .then<LinkPreview?>(
          (value) => value,
          onError: (Object error, StackTrace stack) => null,
        );
    setState(() {
      _future = request;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<LinkPreview?>(
    future: _future,
    builder: (context, snapshot) {
      final preview = snapshot.data;
      final failed =
          snapshot.hasError ||
          (_future != null &&
              snapshot.connectionState == ConnectionState.done &&
              preview == null);
      final target = preview?.resolved ?? widget.url;
      final colors = Theme.of(context).colorScheme;
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onOpen(target),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (preview?.image != null)
                RemoteImage(
                  key: ValueKey(preview!.image),
                  url: preview.image!,
                  service: widget.model.previews,
                  height: preview.isImage ? 260 : 160,
                  onTap: preview.isImage
                      ? () => _showImage(context, preview.image!)
                      : () => widget.onOpen(target),
                ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          preview?.redirected == true
                              ? Icons.alt_route
                              : Icons.language,
                          size: 16,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            target.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.primary,
                            ),
                          ),
                        ),
                        const Icon(Icons.open_in_new, size: 16),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      preview?.title ?? widget.url.toString(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (preview?.description.isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          preview!.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (preview?.redirected == true)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '原短網址：${widget.url.host}',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (snapshot.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    if (_future == null || failed)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              failed ? '無法取得卡片，仍可點擊開啟網頁' : '點擊可在 App 內開啟',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _load,
                            child: Text(failed ? '重試預覽' : '載入預覽'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  void _showImage(BuildContext context, Uri url) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 800),
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                const Expanded(child: Text('圖片預覽・可縮放')),
                IconButton(
                  tooltip: '開啟圖片網址',
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onOpen(url);
                  },
                  icon: const Icon(Icons.open_in_new),
                ),
                IconButton(
                  tooltip: '關閉',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Expanded(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: RemoteImage(
                  url: url,
                  service: widget.model.previews,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class RemoteImage extends StatefulWidget {
  const RemoteImage({
    super.key,
    required this.url,
    required this.service,
    this.height,
    this.onTap,
    this.fit = BoxFit.cover,
  });
  final Uri url;
  final LinkPreviewService service;
  final double? height;
  final VoidCallback? onTap;
  final BoxFit fit;
  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  late Future<Uint8List> _future;
  @override
  void initState() {
    super.initState();
    _future = widget.service.image(widget.url);
  }

  @override
  void didUpdateWidget(covariant RemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _future = widget.service.image(widget.url);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const SizedBox.shrink();
      if (!snapshot.hasData) {
        return SizedBox(
          height: widget.height ?? 120,
          child: const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      return GestureDetector(
        onTap: widget.onTap,
        child: Image.memory(
          snapshot.data!,
          fit: widget.fit,
          height: widget.height,
          width: double.infinity,
          cacheWidth: 1000,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    },
  );
}
