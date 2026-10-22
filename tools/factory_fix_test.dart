// Valida el connectionFactory CORREGIDO (uri.host/uri.port) de punta a punta.
import 'dart:convert';
import 'dart:io';

const uaSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const uaIos =
    'com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X)';

HttpClient nuevoHttp() {
  final hc = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30);
  hc.connectionFactory = (uri, proxyHost, proxyPort) async {
    final realHost = uri.host;
    final realPort = uri.port;
    Future<Socket> future;
    try {
      final addrs = await InternetAddress.lookup(realHost,
          type: InternetAddressType.IPv4);
      future = addrs.isEmpty
          ? Socket.connect(realHost, realPort,
              timeout: const Duration(seconds: 30))
          : Socket.connect(addrs.first, realPort,
              timeout: const Duration(seconds: 30));
    } catch (_) {
      future = Socket.connect(realHost, realPort,
          timeout: const Duration(seconds: 30));
    }
    return ConnectionTask.fromSocket(future, () {
      future.then((s) => s.destroy(), onError: (_) {});
    });
  };
  return hc;
}

Future<void> main() async {
  final hc = nuevoHttp();
  final uri = Uri.parse(
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');
  final body = jsonEncode({
    'videoId': 'eVli-tstM5E',
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
  final req = await hc.postUrl(uri);
  req.headers.contentType =
      ContentType('application', 'json', charset: 'utf-8');
  req.headers.set('User-Agent', uaSafari);
  req.headers.set('Referer', 'https://www.youtube.com/');
  req.write(body);
  final resp = await req.close();
  stdout.writeln('player HTTP ${resp.statusCode}');
  final text = await resp.transform(utf8.decoder).join();
  if (resp.statusCode != 200) {
    stdout.writeln(text.substring(0, text.length.clamp(0, 300)));
    hc.close(force: true);
    return;
  }
  final pj = jsonDecode(text) as Map<String, dynamic>;
  final sd = pj['streamingData'] as Map<String, dynamic>? ?? {};
  final audio = ((sd['adaptiveFormats'] as List?) ?? const [])
      .where((f) =>
          f is Map &&
          f['url'] != null &&
          (f['mimeType'] as String? ?? '').startsWith('audio/'))
      .toList();
  stdout.writeln('audio directo: ${audio.length}');
  final hls = sd['hlsManifestUrl'] as String?;
  stdout.writeln('hls: ${hls != null}');
  final target = audio.isNotEmpty
      ? (audio.first as Map)['url'] as String
      : hls;
  if (target == null) {
    stdout.writeln('SIN URLS - tarjeta sin download');
    hc.close(force: true);
    return;
  }
  // Descarga estilo _openVideo con el MISMO cliente compartido.
  final dreq = await hc.getUrl(Uri.parse(target));
  dreq.headers.set('User-Agent', uaIos);
  dreq.headers.set('Referer', 'https://www.youtube.com/');
  final dresp = await dreq.close();
  stdout.writeln('descarga HTTP ${dresp.statusCode}');
  var bytes = 0;
  await for (final ch in dresp) {
    bytes += ch.length;
    if (bytes > 8192) break;
  }
  stdout.writeln('bytes recibidos: $bytes+');
  hc.close(force: true);
  stdout.writeln('TEST COMPLETADO SIN NULL-CHECK');
}
