// ¿El nodo rr3---sn-uvu5a2a5t-bqaz (el de su telefono) responde mal
// aunque la IP coincida? Pide varios streams y prueba su host exacto.
import 'dart:convert';
import 'dart:io';

const uaSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const uaIos =
    'com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X)';
const targetHost = 'rr3---sn-uvu5a2a5t-bqaz.googlevideo.com';

Future<void> main() async {
  final hosts = <String>{};
  String? sampleUrl;
  for (var i = 0; i < 5; i++) {
    final hc = HttpClient()..connectionTimeout = const Duration(seconds: 20);
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
    final text = await resp.transform(utf8.decoder).join();
    hc.close(force: true);
    if (resp.statusCode != 200) {
      stdout.writeln('player $i -> HTTP ${resp.statusCode}');
      continue;
    }
    final pj = jsonDecode(text) as Map<String, dynamic>;
    final sd = pj['streamingData'] as Map<String, dynamic>? ?? {};
    final audio = ((sd['adaptiveFormats'] as List?) ?? const [])
        .where((f) =>
            f is Map &&
            f['url'] != null &&
            (f['mimeType'] as String? ?? '').startsWith('audio/'))
        .map((f) => (f as Map)['url'] as String)
        .toList();
    if (audio.isEmpty) continue;
    final u = audio.first;
    final m = RegExp(r'https://([^/]+)\.googlevideo\.com').firstMatch(u);
    final host = m != null ? '${m.group(1)}.googlevideo.com' : '?';
    hosts.add(host);
    sampleUrl ??= u;
    stdout.writeln('player $i -> host: $host');
    await Future.delayed(const Duration(milliseconds: 400));
  }
  stdout.writeln('hosts vistos: ${hosts.join(", ")}');
  if (sampleUrl == null) return;

  // Probar el host EXACTO del telefono con una URL propia.
  final swapped = sampleUrl.replaceFirst(
      RegExp(r'https://[^/]+\.googlevideo\.com'), 'https://$targetHost');
  stdout.writeln('probando host del telefono: $targetHost');
  await probe('A) host original (el mio)', sampleUrl);
  await probe('B) host del telefono (swap)', swapped);
}

Future<void> probe(String label, String url) async {
  final hc = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await hc.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', uaIos);
    req.headers.set('Referer', 'https://www.youtube.com/');
    final resp = await req.close();
    var bytes = 0;
    if (resp.statusCode < 400) {
      await for (final ch in resp) {
        bytes += ch.length;
        if (bytes > 4096) break;
      }
      stdout.writeln('[$label] -> HTTP ${resp.statusCode} ($bytes+ bytes)');
    } else {
      stdout.writeln('[$label] -> HTTP ${resp.statusCode}  <<<<<<');
    }
  } catch (e) {
    stdout.writeln('[$label] -> EXCEPCION: $e');
  } finally {
    hc.close(force: true);
  }
}
