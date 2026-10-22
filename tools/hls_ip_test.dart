// ¿El manifiest HLS de YouTube y sus segmentos llevan ip= ?
import 'dart:convert';
import 'dart:io';

const uaSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

Future<void> main() async {
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
  final pj =
      jsonDecode(await presp.transform(utf8.decoder).join()) as Map<String, dynamic>;
  final hls = (pj['streamingData'] as Map)['hlsManifestUrl'] as String?;
  stdout.writeln('hlsManifestUrl: ${hls == null ? "NO" : "si"}');
  if (hls == null) return;
  stdout.writeln('  manifest ip=: ${hls.contains("ip=")}');

  final mreq = await hc.getUrl(Uri.parse(hls));
  mreq.headers.set('User-Agent', uaSafari);
  mreq.headers.set('Referer', 'https://www.youtube.com/');
  final mresp = await mreq.close();
  final master = await mresp.transform(utf8.decoder).join();
  stdout.writeln('manifest HTTP ${mresp.statusCode}, ${master.length} chars');
  final lines = master.split('\n').where((l) => l.trim().isNotEmpty).toList();
  // Elegir la variante de audio (o la primera URL).
  String? variant;
  String? videoVariant;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
      final uri2 = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
      if (uri2.startsWith('http')) {
        final isAudio = lines[i].contains('AUDIO="yes"') ||
            lines[i].contains('AUDIO="1"') == false && lines[i].contains('CODECS="mp4a');
        if (isAudio && variant == null) variant = uri2;
        if (videoVariant == null && lines[i].contains('RESOLUTION')) videoVariant = uri2;
      }
    }
  }
  final target = variant ?? videoVariant;
  if (target == null) {
    stdout.writeln('sin variantes; primeras lineas:\n${lines.take(4).join("\n")}');
    hc.close(force: true);
    return;
  }
  stdout.writeln('variante: ${target.substring(0, target.length.clamp(0, 120))}...');
  stdout.writeln('  variante ip=: ${target.contains("ip=")}');

  final vreq = await hc.getUrl(Uri.parse(target));
  vreq.headers.set('User-Agent', uaSafari);
  vreq.headers.set('Referer', 'https://www.youtube.com/');
  final vresp = await vreq.close();
  final media = await vresp.transform(utf8.decoder).join();
  stdout.writeln('playlist HTTP ${vresp.statusCode}, ${media.length} chars');
  final seg = media.split('\n').firstWhere((l) => l.startsWith('http'),
      orElse: () => '');
  if (seg.isEmpty) {
    // puede ser relativa
    final rel = media.split('\n').firstWhere((l) => l.trim().isNotEmpty && !l.startsWith('#'), orElse: () => '');
    stdout.writeln('segmento relativo: ${rel.substring(0, rel.length.clamp(0, 100))}');
  } else {
    stdout.writeln('segmento ip=: ${seg.contains("ip=")}');
    stdout.writeln('segmento: ${seg.substring(0, seg.length.clamp(0, 140))}...');
    // probar descarga del segmento
    final sreq = await hc.getUrl(Uri.parse(seg));
    sreq.headers.set('User-Agent', uaSafari);
    sreq.headers.set('Referer', 'https://www.youtube.com/');
    final sresp = await sreq.close();
    var bytes = 0;
    await for (final ch in sresp) {
      bytes += ch.length;
      if (bytes > 2048) break;
    }
    stdout.writeln('segmento HTTP ${sresp.statusCode} ($bytes+ bytes)');
  }
  hc.close(force: true);
}
