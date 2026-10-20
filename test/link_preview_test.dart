import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ptt_client/services/link_preview.dart';

UrlGuard publicGuard() =>
    UrlGuard(lookup: (_) async => [InternetAddress('8.8.8.8')]);

void main() {
  test(
    'short URLs follow redirects and read relative Open Graph images',
    () async {
      final calls = <String>[];
      final service = LinkPreviewService(
        guard: publicGuard(),
        client: MockClient((request) async {
          calls.add(request.url.toString());
          if (request.url.host == 'short.example') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://news.example/article'},
            );
          }
          return http.Response(
            '<meta property="og:title" content="測試標題"><meta property="og:description" content="摘要"><meta property="og:image" content="/cover.png">',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );
      final original = Uri.parse('https://short.example/a');
      final result = await service.preview(original);
      expect(result.resolved.toString(), 'https://news.example/article');
      expect(result.title, '測試標題');
      expect(result.description, '摘要');
      expect(result.image.toString(), 'https://news.example/cover.png');
      expect(result.redirected, isTrue);
      await service.preview(original);
      expect(calls.length, 2);
      service.close();
    },
  );
  test('parallel requests for the same URL share a fetch', () async {
    var count = 0;
    final service = LinkPreviewService(
      guard: publicGuard(),
      client: MockClient((_) async {
        count++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response('<title>hello</title>', 200);
      }),
    );
    final url = Uri.parse('https://example.com/read');
    await Future.wait([service.preview(url), service.preview(url)]);
    expect(count, 1);
    service.close();
  });
  test('private redirect is blocked before the next request', () async {
    var count = 0;
    final service = LinkPreviewService(
      guard: publicGuard(),
      client: MockClient((_) async {
        count++;
        return http.Response(
          '',
          302,
          headers: {'location': 'http://127.0.0.1/admin'},
        );
      }),
    );
    await expectLater(
      service.preview(Uri.parse('https://short.example/a')),
      throwsA(isA<PreviewException>()),
    );
    expect(count, 1);
    service.close();
  });
  test(
    'DNS private addresses, credentials and local IPv6 are blocked',
    () async {
      final guard = UrlGuard(
        lookup: (_) async => [InternetAddress('192.168.1.2')],
      );
      for (final raw in [
        'https://local.example/',
        'http://localhost/',
        'file:///etc/passwd',
        'http://[::1]/',
        'http://[::ffff:127.0.0.1]/',
        'https://user:password@example.com',
      ]) {
        await expectLater(
          guard.check(Uri.parse(raw)),
          throwsA(isA<PreviewException>()),
          reason: raw,
        );
      }
      expect(
        UrlGuard.isPublicAddress(InternetAddress('2001:4860:4860::8888')),
        isTrue,
      );
    },
  );
  test('redirect cycles stop; images use the same redirect guard', () async {
    final service = LinkPreviewService(
      guard: publicGuard(),
      client: MockClient(
        (request) async => http.Response(
          '',
          302,
          headers: {'location': request.url.path == '/a' ? '/b' : '/a'},
        ),
      ),
    );
    await expectLater(
      service.preview(Uri.parse('https://example.com/a')),
      throwsA(isA<PreviewException>()),
    );
    await expectLater(
      service.image(Uri.parse('http://10.0.0.1/a.png')),
      throwsA(isA<PreviewException>()),
    );
    service.close();
  });
  test(
    'metadata and images share a limit of three concurrent downloads',
    () async {
      var active = 0, maximum = 0;
      final service = LinkPreviewService(
        guard: publicGuard(),
        client: MockClient((_) async {
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return http.Response('<title>hello</title>', 200);
        }),
      );
      await Future.wait(
        List.generate(
          9,
          (i) => service.preview(Uri.parse('https://example.com/$i')),
        ),
      );
      expect(maximum, 3);
      service.close();
    },
  );
  test('binary image links are recognized without parsing HTML', () async {
    final service = LinkPreviewService(
      guard: publicGuard(),
      client: MockClient(
        (_) async => http.Response.bytes(
          [137, 80, 78, 71],
          200,
          headers: {'content-type': 'image/png'},
        ),
      ),
    );
    final preview = await service.preview(
      Uri.parse('https://example.com/a.png'),
    );
    expect(preview.isImage, isTrue);
    expect(preview.image.toString(), 'https://example.com/a.png');
    service.close();
  });
}
