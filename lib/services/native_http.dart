import 'dart:io';
import 'package:http/io_client.dart';

HttpClient nativeHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 12)
  ..findProxy = HttpClient.findProxyFromEnvironment
  ..userAgent =
      'ptt-client/0.1.2 (+https://github.com/chikenscrach/ptt-client)';

IOClient nativeClient() => IOClient(nativeHttpClient());
