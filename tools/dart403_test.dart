// Reproduce EXACTAMENTE el flujo de IosEngine (player Dart + descarga)
// para cazar el 403: mismas cabeceras, mismo orden.
import 'dart:convert';
import 'dart:io';

const uaSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const uaIosClient =
    'com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X)';

Future<void> main() async {
  // 1) Player desde Dart (como _playerViaDart) — cliente IOS.
  final hc = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final uri = Uri.parse(
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');
  final body = jsonEncode({
    'videoId': 'dQw4w9WgXcQ',
    'contentCheckOk': true,
    'racyCheckOk': true,
    'context': {
      'client': {
        'clientName': 'IOS',
        'clientVersion': '20.10.38',
        'deviceModel': 'iPhone16,2',
        'hl': 'es',
        'gl': 'MX',
      }
    },
  });
  final preq = await hc.postUrl(uri);
  preq.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  preq.headers.set('User-Agent', uaSafari);
  preq.headers.set('Referer', 'https://www.youtube.com/');
  preq.write(body);
  final presp = await preq.close();
  final ptext = await presp.transform(utf8.decoder).join();
  stdout.writeln('player HTTP ${presp.statusCode}');
  if (presp.statusCode != 200) {
    stdout.writeln(ptext.substring(0, ptext.length.clamp(0, 400)));
    hc.close(force: true);
    return;
  }
  final pj = jsonDecode(ptext) as Map<String, dynamic>;
  final sd = pj['streamingData'] as Map<String, dynamic>;
  final audio = ((sd['adaptiveFormats'] as List?) ?? const [])
      .where((f) => f is Map && f['url'] != null && (f['mimeType'] as String? ?? '').startsWith('audio/'))
      .map((f) => Map<String, dynamic>.from(f as Map))
      .toList()
    ..sort((a, b) => ((b['bitrate'] ?? 0) as num).compareTo((a['bitrate'] ?? 0) as num));
  final audioUrl = audio.first['url'] as String;
  stdout.writeln('audio url: ${audioUrl.substring(0, audioUrl.length.clamp(0, 120))}...');
  if (audioUrl.contains('ip=')) stdout.writeln('ip= embebido: si');
  hc.close(force: true);

  // 2) Descarga estilo _openVideo: sin cookies, sin Range (capa1).
  await probar('A: UA cliente IOS, sin cookies, sin Range', audioUrl,
      uaIosClient, useRange: false);
  // 3) Capa3: con Range.
  await probar('B: UA cliente IOS, sin cookies, CON Range', audioUrl,
      uaIosClient, useRange: true);
  // 4) Con cookies de ejemplo.
  await probar('C: UA cliente IOS, CON cookies, sin Range', audioUrl,
      uaIosClient,
      useRange: false, cookies: 'VISITOR_INFO1_LIVE=abc; SOCS=1');
  // 5) Safari UA.
  await probar('D: UA Safari, sin cookies, sin Range', audioUrl, uaSafari,
      useRange: false);
}

Future<void> probar(String etiqueta, String url, String ua,
    {required bool useRange, String? cookies}) async {
  final hc = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await hc.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', ua);
    req.headers.set('Referer', 'https://www.youtube.com/');
    if (cookies != null) req.headers.set('Cookie', cookies);
    if (useRange) req.headers.add('range', 'bytes=0-');
    final resp = await req.close();
    stdout.writeln('[$etiqueta] -> HTTP ${resp.statusCode}');
    if (resp.statusCode >= 400) {
      stdout.writeln('  cabeceras respuesta:');
      resp.headers.forEach((name, values) {
        stdout.writeln('    $name: ${values.join(",")}');
      });
      final body = await resp.transform(utf8.decoder).join();
      stdout.writeln('  cuerpo: ${body.substring(0, body.length.clamp(0, 300))}');
    } else {
      var bytes = 0;
      await for (final chunk in resp) {
        bytes += chunk.length;
        if (bytes > 4096) break;
      }
      stdout.writeln('  descarga OK ($bytes+ bytes)');
    }
  } catch (e) {
    stdout.writeln('[$etiqueta] -> EXCEPCION: $e');
  } finally {
    hc.close(force: true);
  }
}
