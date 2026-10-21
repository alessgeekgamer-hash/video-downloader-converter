import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'download_service.dart';

/// Motor de descarga para iOS.
///
/// iOS prohíbe ejecutar binarios (yt-dlp/ffmpeg), así que este motor trabaja
/// "en proceso": captura las direcciones del video desde el navegador
/// integrado (WebView) y descarga por HTTP, usando ffmpeg-kit (ffmpeg como
/// librería interna) para unir segmentos HLS y convertir a MP3.
class IosEngine implements DownloadService {
  IosEngine._();
  static final IosEngine instance = IosEngine._();

  static const ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  final _controller = StreamController<EngineEvent>.broadcast();
  final Map<String, HttpClient> _clients = {};
  final Map<String, bool> _canceled = {};

  /// Último stream .m3u8 visto en el navegador ( TikTok reproduce HLS ).
  String? lastStreamUrl;
  String? lastStreamHeadersPage;

  @override
  Stream<EngineEvent> get events => _controller.stream;

  void _emit(EngineEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  @override
  Future<Map<String, dynamic>> initEngine() async {
    return {'ok': true, 'version': 'Motor iOS (descarga en proceso)'};
  }

  @override
  Future<bool> ensureStorage() async => true;

  @override
  Future<Directory> downloadDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/VideoDownloader');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  @override
  Future<String?> pickDirectory() async => null; // iOS: sandbox Documents

  @override
  Future<String> updateEngine() async =>
      'El motor de iOS se actualiza instalando la IPA nueva';

  @override
  Future<void> openFile(String path) async {} // Los archivos quedan en Archivos

  @override
  Future<void> cancel(String id) async {
    _canceled[id] = true;
    _clients.remove(id)?.close(force: true);
    _emit(EngineEvent(id: id, type: 'error', message: 'Cancelado'));
  }

  // =========================================================================
  //  Ruta general (usada desde Inicio cuando la URL es descargable directo)
  // =========================================================================

  @override
  Future<void> startDownload({
    required String id,
    required String url,
    required bool audioOnly,
    required int maxHeight,
    String? folder,
  }) async {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message:
              'En iOS abre el video en la pestaña YouTube y usa su botón Descargar'));
      return;
    }
    if (lower.contains('tiktok.com') || lower.contains('vm.tiktok')) {
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message:
              'En iOS abre el video en la pestaña TikTok y usa su botón Descargar'));
      return;
    }
    if (lower.contains('.m3u8')) {
      await _run(id, () => _downloadHls(id, url, audioOnly: audioOnly));
      return;
    }
    await _run(id, () => _downloadDirect(id, url, audioOnly: audioOnly));
  }

  Future<void> _run(String id, Future<void> Function() body) async {
    _canceled[id] = false;
    _emit(EngineEvent(id: id, type: 'start'));
    try {
      await body();
    } catch (e) {
      if (_canceled[id] == true) return;
      _emit(EngineEvent(
          id: id, type: 'error', message: 'Error de descarga: ${e.toString()}'));
    }
  }

  // =========================================================================
  //  Desde las pestañas del navegador (YouTube / TikTok / genérico)
  // =========================================================================

  /// Descarga el video actual del navegador. Primero intenta leer la fuente
  /// del elemento <video> de la página; para YouTube usa el player response.
  Future<void> downloadFromWebTab({
    required String id,
    required InAppWebViewController controller,
    required bool audioOnly,
    required int maxHeight,
    String? fallbackStreamUrl,
    String? fallbackPageUrl,
  }) async {
    _canceled[id] = false;
    _emit(EngineEvent(id: id, type: 'start'));
    try {
      final pageUrl =
          (await controller.getUrl())?.toString().toLowerCase() ?? '';

      // ---- YouTube: player response del sitio (URLs progresivas con audio)
      if (pageUrl.contains('youtube.com') || pageUrl.contains('youtu.be')) {
        await _youtubeFromPage(id, controller, audioOnly, maxHeight);
        return;
      }

      // ---- TikTok y demás: fuente del elemento <video>
      final raw = await controller.evaluateJavascript(
          source:
              "(()=>{const v=document.querySelector('video');return v?(v.currentSrc||v.src||''):''})()");
      var src = (raw is String) ? raw.trim() : '';

      if (src.isEmpty && fallbackStreamUrl != null) src = fallbackStreamUrl;
      if (src.isEmpty || !src.startsWith('http')) {
        _emit(EngineEvent(
            id: id,
            type: 'error',
            message:
                'No se encontró el video. Reproduce el video (o ábrelo) e inténtalo de nuevo'));
        return;
      }

      final page = fallbackPageUrl ?? pageUrl;
      final headers = <String, String>{
        'User-Agent': ua,
        'Referer': page.isEmpty ? 'https://www.tiktok.com/' : page,
      };

      if (src.contains('.m3u8')) {
        await _downloadHls(id, src,
            headers: headers, audioOnly: audioOnly, title: null);
      } else {
        await _downloadDirect(id, src,
            headers: headers, audioOnly: audioOnly);
      }
    } catch (e) {
      if (_canceled[id] == true) return;
      _emit(EngineEvent(
          id: id, type: 'error', message: 'Error: ${e.toString()}'));
    }
  }

  Future<void> _youtubeFromPage(String id, InAppWebViewController controller,
      bool audioOnly, int maxHeight) async {
    const js = r'''
(() => {
  try {
    const p = window.ytInitialPlayerResponse;
    if (!p || !p.streamingData) return null;
    const f = (p.streamingData.formats || []).filter(x => x.url);
    return JSON.stringify({
      title: (p.videoDetails && p.videoDetails.title) || "Video",
      formats: f.map(x => ({
        itag: x.itag, url: x.url, h: x.height || 0,
        w: x.width || 0, mime: x.mimeType || ""
      }))
    });
  } catch (e) { return null; }
})()
''';
    final raw = await controller.evaluateJavascript(source: js);
    if (raw == null || (raw is String && raw.isEmpty)) {
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message:
              'YouTube no ofreció descarga directa para este video en iOS (prueba en la pestaña Universal con otra fuente)'));
      return;
    }
    final data = jsonDecode(raw is String ? raw : raw.toString())
        as Map<String, dynamic>;
    final title = (data['title'] as String?) ?? 'video';
    final formats = (data['formats'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((f) => f['url'] != null)
        .toList()
      ..sort((a, b) => (b['h'] as int).compareTo(a['h'] as int));

    Map<String, dynamic>? chosen;
    for (final f in formats) {
      final h = f['h'] as int;
      if (maxHeight <= 0 || h <= maxHeight || chosen == null) chosen = f;
      if (maxHeight > 0 && h >= maxHeight) break;
    }
    if (chosen == null) {
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message: 'YouTube no tiene formato progresivo disponible'));
      return;
    }
    final h = chosen['h'] as int;
    final url = chosen['url'] as String;
    _emit(EngineEvent(
        id: id, type: 'progress', progress: 0, message: 'YouTube ${h}p'));

    await _downloadDirect(id, url,
        audioOnly: audioOnly, title: title, extraHeaders: {
      'User-Agent': ua,
      'Referer': 'https://www.youtube.com/',
    });
  }

  // =========================================================================
  //  Pestaña Universal (solo análisis simple sin navegador)
  // =========================================================================

  Future<Map<String, dynamic>> analyzeUniversal(String url) async {
    final lower = url.toLowerCase();
    if (lower.contains('youtube.com') || lower.contains('youtu.be')) {
      return {
        'ok': false,
        'error': 'En iOS usa la pestaña YouTube (abre el video ahí)'
      };
    }
    if (lower.contains('.m3u8')) {
      return _universalOk(url, 'HLS', _basename(url));
    }
    if (RegExp(r'\.(mp4|mov|m4v|webm|mkv)(\?|$)').hasMatch(lower)) {
      return _universalOk(url, 'Directo', _basename(url));
    }
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', ua);
      req.followRedirects = true;
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final html = await resp.transform(utf8.decoder).join();
      client.close(force: true);

      String? media;
      // \x22 = comilla doble, \x27 = comilla simple (evita romper strings).
      final patterns = [
        RegExp(r'property=[\x22\x27]og:video[\x22\x27]\s+content=[\x22\x27]([^\x22\x27]+)[\x22\x27]',
            caseSensitive: false),
        RegExp(r'content=[\x22\x27]([^\x22\x27]+)[\x22\x27]\s+property=[\x22\x27]og:video[\x22\x27]',
            caseSensitive: false),
        RegExp(r'<video[^>]+src=[\x22\x27]([^\x22\x27]+)[\x22\x27]', caseSensitive: false),
        RegExp(r'<source[^>]+src=[\x22\x27]([^\x22\x27]+)[\x22\x27]', caseSensitive: false),
        RegExp(r'https?://[^\s\x22\x27<>]+\.m3u8[^\s\x22\x27<>]*', caseSensitive: false),
      ];
      for (final re in patterns) {
        final m = re.firstMatch(html);
        if (m != null) {
          media = (m.groupCount > 0 ? m.group(1) : m.group(0))!;
          break;
        }
      }
      if (media == null) {
        return {
          'ok': false,
          'error':
              'La página no expone un video directo. Abre el video y copia el enlace del archivo o usa la pestaña del sitio'
        };
      }
      if (media.startsWith('//')) media = 'https:$media';
      final isHls = media.contains('.m3u8');
      final t = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false)
          .firstMatch(html);
      final pageTitle = t != null
          ? t.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ')
          : _basename(media);
      return _universalOk(media, isHls ? 'HLS' : 'Directo', pageTitle);
    } catch (e) {
      return {'ok': false, 'error': 'No se pudo leer la página'};
    }
  }

  Map<String, dynamic> _universalOk(String media, String kind, String title) {
    return {
      'ok': true,
      'title': title,
      'thumbnail': null,
      'duration': 0,
      'extractor': kind,
      'webpage_url': media,
    };
  }

  /// Descarga desde la pestaña Universal (media ya analizado).
  Future<void> downloadUniversal({
    required String id,
    required String mediaUrl,
    required bool audioOnly,
  }) {
    _canceled[id] = false;
    _emit(EngineEvent(id: id, type: 'start'));
    return _run(id, () async {
      if (mediaUrl.contains('.m3u8')) {
        await _downloadHls(id, mediaUrl, audioOnly: audioOnly);
      } else {
        await _downloadDirect(id, mediaUrl, audioOnly: audioOnly);
      }
    });
  }

  /// Convierte un archivo local (elegido por el usuario) a MP3.
  Future<void> convertLocal(String id, String inputPath) async {
    _canceled[id] = false;
    _emit(EngineEvent(id: id, type: 'start'));
    await _run(id, () async {
      final dir = await downloadDir();
      final name = _basename(inputPath).replaceAll(RegExp(r'\.[^.]+$'), '');
      final outPath = '${dir.path}/$name.mp3';
      await _convertMp3(id, inputPath, outPath);
      _emit(EngineEvent(id: id, type: 'done', progress: 100, path: outPath));
    });
  }

  // =========================================================================
  //  Descarga directa (mp4 u otro archivo)
  // =========================================================================

  Future<void> _downloadDirect(
    String id,
    String url, {
    Map<String, String>? headers,
    bool audioOnly = false,
    String? title,
    Map<String, String>? extraHeaders,
  }) async {
    final dir = await downloadDir();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    _clients[id] = client;

    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', ua);
    (headers ?? extraHeaders ?? const {}).forEach((k, v) {
      if (k.toLowerCase() != 'user-agent') req.headers.set(k, v);
    });
    if (extraHeaders != null) {
      extraHeaders.forEach((k, v) => req.headers.set(k, v));
    }

    final resp = await req.close();
    if (resp.statusCode >= 400) {
      client.close(force: true);
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message: 'El servidor respondió HTTP ${resp.statusCode}'));
      return;
    }

    final total = resp.contentLength;
    var received = 0;
    var lastPct = -1.0;

    final tmp = File('${dir.path}/$id.part');
    final sink = tmp.openWrite();
    final completer = Completer<void>();

    resp.listen(
      (chunk) {
        if (_canceled[id] == true) {
          sink.close();
          if (!completer.isCompleted) completer.completeError('cancel');
          return;
        }
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) {
          final pct = (received * 100 / total).floorToDouble();
          if (pct != lastPct) {
            lastPct = pct;
            _emit(EngineEvent(id: id, type: 'progress', progress: pct));
          }
        }
      },
      onDone: () async {
        await sink.close();
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) async {
        await sink.close();
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );

    await completer.future;
    _clients.remove(id);
    if (_canceled[id] == true) return;

    final name = (title ?? _basename(url)).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final ext = _extFrom(url, resp.headers.contentType?.mimeType);
    var finalPath = '${dir.path}/$name.$ext';

    if (audioOnly) {
      final mp3Path = '${dir.path}/$name.mp3';
      await _convertMp3(id, tmp.path, mp3Path);
      tmp.deleteSync();
      _emit(EngineEvent(id: id, type: 'done', progress: 100, path: mp3Path));
      return;
    }

    final f = File(finalPath);
    if (f.existsSync()) f.deleteSync();
    tmp.renameSync(finalPath);
    _emit(EngineEvent(id: id, type: 'done', progress: 100, path: finalPath));
  }

  // =========================================================================
  //  HLS (TikTok y sitios con .m3u8)
  // =========================================================================

  Future<void> _downloadHls(
    String id,
    String playlistUrl, {
    Map<String, String>? headers,
    bool audioOnly = false,
    String? title,
  }) async {
    final dir = await downloadDir();
    final workDir = Directory('${dir.path}/$id.hls');
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    workDir.createSync(recursive: true);

    var mediaUrl = playlistUrl;
    var playlist = await _getText(mediaUrl, headers);

    // Playlista maestra: elegir la mejor variante.
    if (playlist.contains('#EXT-X-STREAM-INF')) {
      final lines = playlist.split('\n');
      var bestH = -1;
      String? bestUrl;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
          final h = res != null ? int.parse(res.group(2)!) : 0;
          if (i + 1 < lines.length) {
            final uri = lines[i + 1].trim();
            if (uri.isNotEmpty && !uri.startsWith('#') && h > bestH) {
              bestH = h;
              bestUrl = _absUrl(mediaUrl, uri);
            }
          }
        }
      }
      if (bestUrl == null) {
        _emit(EngineEvent(
            id: id, type: 'error', message: 'Lista HLS sin variantes'));
        return;
      }
      mediaUrl = bestUrl;
      _emit(EngineEvent(
          id: id, type: 'progress', progress: 1, message: '${bestH}p'));
      playlist = await _getText(mediaUrl, headers);
    }

    // Extraer mapa de inicialización y segmentos.
    String? initUrl;
    final mapMatch =
        RegExp(r'#EXT-X-MAP:URI="([^"]+)"').firstMatch(playlist);
    if (mapMatch != null) initUrl = _absUrl(mediaUrl, mapMatch.group(1)!);

    final segments = <String>[];
    final lines = playlist.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('http') || line.contains('/')) {
        segments.add(_absUrl(mediaUrl, line));
      }
    }
    if (segments.isEmpty) {
      _emit(EngineEvent(
          id: id, type: 'error', message: 'La lista HLS no tiene segmentos'));
      return;
    }

    final listFile = File('${workDir.path}/list.txt');
    final sink = listFile.openWrite();

    if (initUrl != null) {
      final initFile = File('${workDir.path}/init.mp4');
      await _downloadSegment(initUrl, initFile, headers);
      sink.writeln("file '${initFile.path}'");
    }
    for (var i = 0; i < segments.length; i++) {
      if (_canceled[id] == true) {
        await sink.close();
        return;
      }
      final segFile = File('${workDir.path}/seg_${i.toString().padLeft(4, '0')}.bin');
      await _downloadSegment(segments[i], segFile, headers);
      sink.writeln("file '${segFile.path}'");
      final pct = ((i + 1) * 100 / segments.length).floorToDouble();
      _emit(EngineEvent(id: id, type: 'progress', progress: pct));
    }
    await sink.close();

    // Unir segmentos con ffmpeg (copia sin recodificar).
    final safeName =
        (title ?? _basename(Uri.parse(mediaUrl).path)).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final joinedPath = '${workDir.path}/$safeName.mp4';
    final session = await FFmpegKit.execute(
        "-y -f concat -safe 0 -i '${listFile.path}' -c copy '$joinedPath'");
    final rc = await session.getReturnCode();
    if (rc == null || !ReturnCode.isSuccess(rc)) {
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message: 'FFmpeg no pudo unir el video (código ${rc?.getValue()}'));
      return;
    }

    if (audioOnly) {
      final mp3Path = '${dir.path}/$safeName.mp3';
      await _convertMp3(id, joinedPath, mp3Path);
      _emit(EngineEvent(id: id, type: 'done', progress: 100, path: mp3Path));
    } else {
      final outPath = '${dir.path}/$safeName.mp4';
      final out = File(outPath);
      if (out.existsSync()) out.deleteSync();
      File(joinedPath).renameSync(outPath);
      _emit(EngineEvent(id: id, type: 'done', progress: 100, path: outPath));
    }
    try {
      workDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  Future<void> _downloadSegment(
      String url, File file, Map<String, String>? headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', ua);
      headers?.forEach((k, v) {
        if (k.toLowerCase() != 'user-agent') req.headers.set(k, v);
      });
      final resp = await req.close();
      await resp.pipe(file.openWrite());
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _getText(String url, Map<String, String>? headers) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', ua);
      headers?.forEach((k, v) {
        if (k.toLowerCase() != 'user-agent') req.headers.set(k, v);
      });
      final resp = await req.close();
      return await resp.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  // =========================================================================
  //  Conversión a MP3 con ffmpeg-kit (librería interna, permitida en iOS)
  // =========================================================================

  Future<void> _convertMp3(String id, String inputPath, String outPath) async {
    _emit(EngineEvent(
        id: id, type: 'progress', progress: 99, message: 'Convirtiendo a MP3'));
    final session = await FFmpegKit.execute(
        '-y -i "$inputPath" -vn -acodec libmp3lame -q:a 0 "$outPath"');
    final rc = await session.getReturnCode();
    if (rc == null || !ReturnCode.isSuccess(rc)) {
      throw Exception('FFmpeg no pudo convertir a MP3');
    }
  }

  // =========================================================================

  String _basename(String url) {
    try {
      final path = Uri.parse(url).path;
      final parts = path.split('/').where((s) => s.isNotEmpty).toList();
      final name = parts.isEmpty ? 'video' : parts.last;
      final cleaned =
          Uri.decodeComponent(name).replaceAll(RegExp(r'\.[^.]+$'), '');
      return cleaned.isEmpty ? 'video' : cleaned;
    } catch (_) {
      return 'video';
    }
  }

  String _absUrl(String base, String rel) {
    if (rel.startsWith('http')) return rel;
    final b = Uri.parse(base);
    if (rel.startsWith('/')) {
      return '${b.scheme}://${b.host}$rel';
    }
    final dir = b.path.substring(0, b.path.lastIndexOf('/') + 1);
    return '${b.scheme}://${b.host}$dir$rel';
  }

  String _extFrom(String url, String? mime) {
    try {
      final path = Uri.parse(url).path.toLowerCase();
      for (final e in ['mp4', 'mov', 'm4v', 'webm', 'mkv', 'mp3']) {
        if (path.endsWith('.$e')) return e;
      }
    } catch (_) {}
    if (mime != null) {
      if (mime.contains('mp4')) return 'mp4';
      if (mime.contains('webm')) return 'webm';
      if (mime.contains('quicktime')) return 'mov';
    }
    return 'mp4';
  }
}
