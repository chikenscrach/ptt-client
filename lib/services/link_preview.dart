import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart3_big5/big5.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'native_http.dart';

typedef HostLookup = Future<List<InternetAddress>> Function(String host);

class PreviewException implements Exception {
  const PreviewException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UrlGuard {
  UrlGuard({HostLookup? lookup}) : _lookup = lookup ?? InternetAddress.lookup;
  final HostLookup _lookup;

  static bool isWebUrl(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 80 || uri.port == 443);

  static bool isPublicAddress(InternetAddress ip) {
    final b = ip.rawAddress;
    if (b.length == 4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 198 && (b[1] == 18 || b[1] == 19)));
    }
    // Only globally routable IPv6 unicast, including safe IPv4-mapped addresses.
    if (b.length == 16) {
      if (b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255) {
        return isPublicAddress(
          InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
        );
      }
      return (b[0] & 0xe0) == 0x20;
    }
    return false;
  }

  Future<void> check(Uri uri) async {
    if (!isWebUrl(uri)) throw const PreviewException('僅支援一般 HTTP／HTTPS 網址。');
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        !host.contains('.') && !host.contains(':')) {
      throw const PreviewException('此網址不是公開網站。');
    }
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null
        ? await _lookup(host).timeout(const Duration(seconds: 5))
        : [literal];
    if (addresses.isEmpty || addresses.any((a) => !isPublicAddress(a))) {
      throw const PreviewException('此網址指向本機或私人網路，已停止自動預覽。');
    }
  }
}

class LinkPreview {
  const LinkPreview({
    required this.original,
    required this.resolved,
    required this.title,
    required this.description,
    this.image,
    this.isImage = false,
  });
  final Uri original, resolved;
  final String title, description;
  final Uri? image;
  final bool isImage;
  bool get redirected => original.removeFragment() != resolved.removeFragment();

  Map<String, Object?> toJson() => {
    'original': original.toString(),
    'resolved': resolved.toString(),
    'title': title,
    'description': description,
    'image': image?.toString(),
    'isImage': isImage,
  };
  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
    original: Uri.parse(json['original'] as String),
    resolved: Uri.parse(json['resolved'] as String),
    title: json['title'] as String,
    description: json['description'] as String,
    image: json['image'] == null ? null : Uri.parse(json['image'] as String),
    isImage: json['isImage'] == true,
  );
}

class _Fetched {
  const _Fetched(this.url, this.bytes, this.type);
  final Uri url;
  final Uint8List bytes;
  final String type;
}

class LinkPreviewService {
  LinkPreviewService({http.Client? client, UrlGuard? guard})
    : _client = client ?? nativeClient(),
      guard = guard ?? UrlGuard();
  final http.Client _client;
  final UrlGuard guard;
  final _cache = <String, (DateTime, LinkPreview)>{};
  final _pending = <String, Future<LinkPreview>>{};
  final _images = <String, Uint8List>{};
  final _waiting = Queue<Completer<void>>();
  int _active = 0;
  bool _closed = false;

  // Share a three-request budget across metadata and image downloads.
  Future<T> _limited<T>(Future<T> Function() action) async {
    if (_closed) throw const PreviewException('預覽服務已關閉。');
    if (_active >= 3) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      if (_closed) throw const PreviewException('預覽服務已關閉。');
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  Future<LinkPreview> preview(Uri url) {
    final key = url.toString();
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(hours: 12)) {
      _cache.remove(key);
      _cache[key] = cached;
      return Future.value(cached.$2);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final value = await _limited(() => _load(url));
        _cache[key] = (DateTime.now(), value);
        while (_cache.length > 128) {
          _cache.remove(_cache.keys.first);
        }
        return value;
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<_Fetched> _fetch(
    Uri input, {
    int limit = 512 * 1024,
    bool imageOnly = false,
  }) async {
    var url = input;
    final seen = <String>{};
    for (var hops = 0; hops <= 6; hops++) {
      await guard.check(url);
      if (!seen.add(url.removeFragment().toString())) {
        throw const PreviewException('短網址出現循環轉址。');
      }
      final request = http.Request('GET', url.removeFragment())
        ..followRedirects = false;
      request.headers['User-Agent'] =
          'ptt-client/0.1.1 (+https://github.com/chikenscrach/ptt-client)';
      request.headers['Accept'] = imageOnly
          ? 'image/*'
          : 'text/html,image/*;q=0.9,*/*;q=0.5';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.listen(null).cancel();
        final location = response.headers['location'];
        if (location == null) throw const PreviewException('網站未提供轉址位置。');
        var next = url.resolve(location);
        if (!Uri.parse(location).hasFragment && url.hasFragment) {
          next = next.replace(fragment: url.fragment);
        }
        url = next;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen(null).cancel();
        throw PreviewException('網站暫時無法預覽（HTTP ${response.statusCode}）。');
      }
      final type = (response.headers['content-type'] ?? '').toLowerCase();
      if (!imageOnly && type.startsWith('image/')) {
        await response.stream.listen(null).cancel();
        return _Fetched(url, Uint8List(0), type);
      }
      if (imageOnly && (!type.startsWith('image/') || type.contains('svg'))) {
        await response.stream.listen(null).cancel();
        throw const PreviewException('此連結不是可預覽的點陣圖片。');
      }
      if (!imageOnly &&
          type.isNotEmpty &&
          !type.contains('html') &&
          !type.startsWith('text/')) {
        await response.stream.listen(null).cancel();
        throw const PreviewException('此連結為檔案，請在網頁瀏覽器中開啟。');
      }
      if ((response.contentLength ?? 0) > limit) {
        await response.stream.listen(null).cancel();
        throw const PreviewException('預覽內容過大，請開啟網頁查看。');
      }
      final bytes = BytesBuilder(copy: false);
      await (() async {
        await for (final chunk in response.stream) {
          bytes.add(chunk);
          if (bytes.length > limit) throw const PreviewException('預覽內容超過大小限制。');
        }
      })().timeout(const Duration(seconds: 12));
      return _Fetched(url, bytes.takeBytes(), type);
    }
    throw const PreviewException('短網址轉址次數過多。');
  }

  Future<LinkPreview> _load(Uri input) async {
    final fetched = await _fetch(input);
    if (fetched.type.startsWith('image/')) {
      return LinkPreview(
        original: input,
        resolved: fetched.url,
        title: fetched.url.pathSegments.lastOrNull ?? '圖片',
        description: '圖片預覽',
        image: fetched.url,
        isImage: true,
      );
    }
    final initial = latin1.decode(fetched.bytes);
    final isBig5 =
        fetched.type.contains('big5') ||
        RegExp(
          r'charset\s*=\s*["\x27]?big5',
          caseSensitive: false,
        ).hasMatch(initial);
    final source = isBig5
        ? Big5.decode(fetched.bytes)
        : utf8.decode(fetched.bytes, allowMalformed: true);
    final doc = html.parse(source);
    String meta(List<String> names) {
      for (final name in names) {
        final value = doc
            .querySelector('meta[property="$name"],meta[name="$name"]')
            ?.attributes['content'];
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
      return '';
    }

    var title = meta(['og:title', 'twitter:title']);
    if (title.isEmpty) {
      title = doc.querySelector('title')?.text.trim() ?? fetched.url.host;
    }
    final imageValue = meta(['og:image', 'twitter:image']);
    Uri? image;
    if (imageValue.isNotEmpty) {
      final candidate = fetched.url.resolve(imageValue);
      if (UrlGuard.isWebUrl(candidate)) image = candidate;
    }
    return LinkPreview(
      original: input,
      resolved: fetched.url,
      title: title.length > 200 ? title.substring(0, 200) : title,
      description: meta([
        'og:description',
        'description',
        'twitter:description',
      ]).charactersSafeTake(400),
      image: image,
    );
  }

  Future<Uint8List> image(Uri url) async {
    final key = url.toString();
    if (_images.containsKey(key)) return _images[key]!;
    final result = await _limited(
      () => _fetch(url, limit: 5 * 1024 * 1024, imageOnly: true),
    );
    _images[key] = result.bytes;
    while (_images.length > 12) {
      _images.remove(_images.keys.first);
    }
    return result.bytes;
  }

  void close() {
    _closed = true;
    _client.close();
  }
}

extension on String {
  String charactersSafeTake(int max) => String.fromCharCodes(runes.take(max));
}
