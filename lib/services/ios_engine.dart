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

  /// UA del cliente InnerTube que entregó el stream — googlevideo exige
  /// el UA del cliente, si no responde HTTP403.
  static String _uaForClient(String? client) {
    switch (client) {
      case 'IOS':
        return 'com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_3 like Mac OS X)';
      case 'ANDROID':
        return 'com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US) gzip';
      case 'MWEB':
        return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
            '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      case 'TVHTML5_SIMPLY_EMBEDDED_PLAYER':
        return 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version';
      default:
        return ua;
    }
  }

  /// HttpClient con IPv4 FORZADO: el ip= del player debe coincidir con el
  /// de la descarga siempre (los carriers moviles rotan IPv4/IPv6).
  /// HttpClient con IPv4 opcional. DESACTIVADO por defecto: en varias redes
  /// (incluida la de pruebas) el forzadoIPv4 cierra la conexion. La
  /// rotacion de IP se cubre con los reintentos de URL fresca.
  HttpClient _newHttp([Duration? timeout, bool pinIpv4 = false]) {
    final hc = HttpClient()
      ..connectionTimeout = timeout ?? const Duration(seconds: 30);
    if (!pinIpv4) return hc;
    try {
      // OJO: los parametros del factory son (url, proxyHost, proxyPort) —
      // host/puerto REALES vienen en la Uri. Ignorar proxy (no usamos).
      hc.connectionFactory = (uri, proxyHost, proxyPort) async {
        final realHost = uri.host;
        final realPort = uri.port;
        Future<Socket> future;
        try {
          // Forzar IPv4: si el carrier usa IPv6 para una peticion y IPv4
          // para otra, el ip= embebido no coincide y googlevideo da403.
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
    } catch (_) {}
    return hc;
  }
  /// Ultimo cliente InnerTube usado (para diagnosticos de error).
  String _lastClient = '';

  /// Cookies de la sesion del navegador (YouTube logueado) para las
  /// peticiones de descarga - googlevideo puede exigirlas.
  String? sessionCookies;

  /// Carga las cookies de YouTube del navegador integrado.
  Future<void> loadCookies(InAppWebViewController controller) async {
    try {
      final cm = CookieManager();
      final parts = <String>[];
      for (final target in [
        'https://www.youtube.com/',
        'https://accounts.google.com/',
      ]) {
        final list = await cm.getCookies(url: WebUri(target));
        for (final c in list) {
          if (c.name.isNotEmpty) parts.add('${c.name}=${c.value}');
        }
      }
      if (parts.isNotEmpty) sessionCookies = parts.join('; ');
    } catch (_) {}
  }

  // IMPORTANTE: googlevideo rechaza con cookies de sesion (403) para
  // descargas anonimas; el player SII las lleva, la descarga NO.
  Map<String, String> _ytHeaders(String clientUa) {
    return {
      'User-Agent': clientUa,
      'Referer': 'https://www.youtube.com/',
    };
  }

  /// Mensaje rico para errores HTTP. Requiere _lastIpCache/_lastCookieSent
  /// llenados justo antes (los llena cada peticion fallida).
  String _httpError(int code, String url) {
    String host;
    try {
      host = Uri.parse(url).host;
    } catch (_) {
      host = '?';
    }
    var extra = '';
    final mIp = RegExp(r'(?:&|/)ip(?:=|/)([0-9a-fA-F.:]+)').firstMatch(url);
    if (mIp != null) extra = ' | ip-url:${mIp.group(1)}';
    final mExp = RegExp(r'expire=(\d+)').firstMatch(url);
    if (mExp != null) {
      final exp = int.tryParse(mExp.group(1)!) ?? 0;
      final delta = exp - DateTime.now().millisecondsSinceEpoch ~/ 1000;
      extra += ' | vence en ${Duration(seconds: delta).inMinutes} min';
    }
    final ipNow = _lastIpCache;
    if (ipNow.isNotEmpty && ipNow != '?') {
      if (mIp != null) {
        extra += mIp.group(1) == ipNow
            ? ' | ip-actual:$ipNow COINCIDE'
            : ' | ip-actual:$ipNow **DIFERENTE**';
      } else {
        extra += ' | ip-actual:$ipNow';
      }
    } else {
      extra += ' | ip-actual:indisponible';
    }
    extra += ' | cookie-env:${_lastCookieSent ? "si" : "NO"}';
    return 'El servidor respondio HTTP $code (host: $host | cliente: '
        '${_lastClient.isEmpty ? "?" : _lastClient}$extra)';
  }

  String _lastIpCache = '';
  bool _lastCookieSent = false;

  /// IP publica actual del dispositivo (diagnostico de 403).
  Future<void> _refreshPublicIp() async {
    try {
      final hc = _newHttp(const Duration(seconds: 6));
      final req = await hc.getUrl(Uri.parse('https://api.ipify.org/'));
      final resp = await req.close();
      final txt = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 6));
      hc.close(force: true);
      _lastIpCache = txt.trim();
    } catch (_) {
      _lastIpCache = '?';
    }
  }

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
    var data = await extractFromPage(controller);
    if ((data['kind'] as String?) == 'none') {
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message:
              'No se pudo leer el reproductor de YouTube (${data['diag'] ?? ''})'));
      return;
    }

    // Reintento anti-403: en carriers moviles la IP puede rotar entre el
    // player y la descarga; se pide una URL fresca y reintenta (3 veces).
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        _emit(EngineEvent(
            id: id,
            type: 'progress',
            progress: 0,
            message: 'Reintento ${attempt + 1}/3 (IP cambio)'));
        await Future.delayed(const Duration(seconds: 2));
        final fresh = await extractFromPage(controller);
        if ((fresh['kind'] as String?) == 'none') break;
        data = fresh;
      }
      try {
        await _ytDownloadStep(id, data, audioOnly, maxHeight);
        return;
      } catch (e) {
        lastError = e;
        if (!e.toString().contains('403')) break;
      }
    }
    _emit(EngineEvent(
        id: id,
        type: 'error',
        message: 'Falló tras reintentos: ${lastError ?? "error desconocido"}'));
  }

  /// Un intento de descarga de YouTube (usado tambien por Universal).
  Future<void> _ytDownloadStep(String id, Map<String, dynamic> data,
      bool audioOnly, int maxHeight) async {
    final kind = (data['kind'] as String?) ?? 'none';
    _lastClient = (data['client'] as String?) ?? 'WEB';
    final clientUa = _uaForClient(_lastClient);
    final ytHeaders = _ytHeaders(clientUa);

    if (kind == 'youtube-hls') {
      final media = (data['media'] as String?) ?? '';
      if (media.isEmpty) throw Exception('Sin manifiest HLS');
      _emit(EngineEvent(
          id: id, type: 'progress', progress: 0, message: 'YouTube HD'));
      await _downloadHls(id, media,
          title: data['title'] as String?,
          audioOnly: audioOnly,
          headers: ytHeaders);
      return;
    }

    if (audioOnly) {
      final audioList = (data['audio'] as List? ?? const []);
      if (audioList.isNotEmpty) {
        final a = Map<String, dynamic>.from(audioList.first as Map);
        _emit(EngineEvent(id: id, type: 'progress', progress: 0));
        await _downloadDirect(id, a['url'] as String,
            audioOnly: true, title: data['title'] as String?, extraHeaders: ytHeaders);
        return;
      }
      final prog0 = (data['progressive'] as List? ?? const []);
      if (prog0.isEmpty) {
        throw Exception(
            'YouTube no ofrecio audio (${data['diag'] ?? ''})');
      }
    }

    final prog = (data['progressive'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (prog.isEmpty) {
      final av = (data['adaptiveVideo'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final audio = (data['audio'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      Map<String, dynamic>? v;
      for (final f in av) {
        final h = (f['h'] as num?)?.toInt() ?? 0;
        if (maxHeight <= 0 || h <= maxHeight || v == null) v = f;
        if (maxHeight > 0 && h >= maxHeight) break;
      }
      if (v != null && audio.isNotEmpty) {
        await _downloadAdaptiveMerge(
          id: id,
          videoUrl: v['url'] as String,
          audioUrl: audio.first['url'] as String,
          title: data['title'] as String?,
          clientUa: clientUa,
        );
        return;
      }
      throw Exception(
          'Este video solo ofrece formatos separados en iOS (elige MP3). ${data['diag'] ?? ''}');
    }
    Map<String, dynamic>? chosen;
    for (final f in prog) {
      final h = (f['h'] as num?)?.toInt() ?? 0;
      if (maxHeight <= 0 || h <= maxHeight || chosen == null) chosen = f;
      if (maxHeight > 0 && h >= maxHeight) break;
    }
    final url = chosen!['url'] as String;
    final h = (chosen['h'] as num?)?.toInt() ?? 0;
    _emit(EngineEvent(
        id: id, type: 'progress', progress: 0, message: 'YouTube ${h}p'));
    await _downloadDirect(id, url,
        audioOnly: audioOnly, title: data['title'] as String?, extraHeaders: ytHeaders);
  }

  /// Extrae TODO lo posible de la página cargada (YouTube u otro sitio).
  /// Devuelve: kind (youtube | youtube-hls | youtube-audio | hls | video |
  /// none), title, thumbnail, duration, progressive[], audio[], media, diag.
  Future<Map<String, dynamic>> extractFromPage(
      InAppWebViewController controller) async {
    // Fase1: fuentes embebidas en la página.
    var data = _decodeJsMap(
        await controller.evaluateJavascript(source: _extractJs));

    // YouTube: SIEMPRE pedir el player desde DART (misma IP de red que la
    // descarga). Las URL embebidas de la pagina (WebKit) se descartan:
    // estan atadas a OTRA IP y causan HTTP403 con ip=.
    final videoId = (data['videoId'] as String?) ?? '';
    final innertubeKey = (data['key'] as String?) ?? '';
    if (videoId.isNotEmpty && data['kind'] != 'none') {
      data['diag'] = '${data['diag'] ?? ''}|web-descartado:${data['kind']}';
      data['kind'] = 'none';
    }
    if (videoId.isNotEmpty) {
      final clients = <Map<String, dynamic>>[
        {
          'clientName': 'IOS',
          'clientVersion': '20.10.38',
          'deviceModel': 'iPhone16,2',
          'hl': 'es',
          'gl': 'MX',
        },
        {
          'clientName': 'ANDROID',
          'clientVersion': '20.10.38',
          'androidSdkVersion': 34,
          'hl': 'es',
          'gl': 'MX',
        },
        {
          'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
          'clientVersion': '2.0',
          'hl': 'es',
          'gl': 'MX',
          'thirdParty': {'embedUrl': 'https://www.google.com/'},
        },
        {
          'clientName': 'MWEB',
          'clientVersion': '2.20250401.01.00',
          'hl': 'es',
          'gl': 'MX',
        },
      ];
      // La peticion se hace DESDE DART (mismo stack de red que la
      // descarga): el servidor ata la URL a la IP que la pidio.
      if (videoId.isEmpty) {
        data['diag'] = '${data['diag'] ?? ''}|sin-video-id';
      }
      for (final cl in clients) {
        if (videoId.isEmpty) break;
        final name = cl['clientName'] as String;
        final pj = await _playerViaDart(
            videoId: videoId, key: innertubeKey, client: cl);
        if (pj == null) {
          data['diag'] = '${data['diag'] ?? ''}|$name:sin-respuesta';
          continue;
        }
        final errText = pj['__error'];
        if (errText != null) {
          data['diag'] = '${data['diag'] ?? ''}|$name:$errText';
          continue;
        }
        final mapped = _mapPlayerJson(pj);
        mapped['client'] = name;
        if (mapped['kind'] != 'none') {
          data = {...data, ...mapped};
          data['diag'] = '${data['diag'] ?? ''}|it:$name';
          break;
        }
        data['diag'] = '${data['diag'] ?? ''}|$name:{${mapped['diag'] ?? ''}}';
      }
    }

    // Fase3: reproducir en silencio y leer currentSrc del <video>.
    if (data['kind'] == 'none') {
      try {
        await controller.evaluateJavascript(source: _autoplayJs);
        await Future.delayed(const Duration(seconds: 4));
        final src = await controller.evaluateJavascript(source: _readSrcJs);
        final s = (src is String) ? src.trim() : '';
        if (s.startsWith('http')) {
          data['media'] = s;
          data['kind'] = s.contains('.m3u8') ? 'hls' : 'video';
          data['diag'] = '${data['diag'] ?? ''}|autoplay-src';
        }
      } catch (_) {}
    }

    // Normalizar listas.
    data['progressive'] = ((data['progressive'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    data['audio'] = ((data['audio'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return data;
  }

  Map<String, dynamic> _decodeJsMap(dynamic raw) {
    try {
      return jsonDecode(raw is String ? raw : jsonEncode(raw))
          as Map<String, dynamic>;
    } catch (_) {
      return {
        'kind': 'none',
        'diag': 'js-invalido',
        'progressive': <Map<String, dynamic>>[],
        'audio': <Map<String, dynamic>>[],
      };
    }
  }

  /// Convierte la respuesta de InnerTube al mismo formato de extractFromPage.
  Map<String, dynamic> _mapPlayerJson(Map<String, dynamic> p) {
    final out = <String, dynamic>{
      'kind': 'none',
      'title': '',
      'thumbnail': '',
      'duration': 0,
      'media': '',
      'progressive': [],
      'audio': [],
      'adaptiveVideo': [],
      'client': '',
      'diag': '',
    };
    final status = (p['playabilityStatus'] as Map<String, dynamic>?);
    final statusReason = (status?['reason'] as String?) ?? '';
    out['diag'] = 'st:${status?['status'] ?? 's-st'}';
    if (statusReason.isNotEmpty) out['diag'] += ' razon:$statusReason';
    final errObj = p['error'] as Map<String, dynamic>?;
    if (errObj != null) {
      out['diag'] += ' error:${errObj['code']}:${errObj['message']}';
    }

    final vd = p['videoDetails'] as Map<String, dynamic>?;
    out['title'] = (vd?['title'] as String?) ?? '';
    out['duration'] = int.tryParse((vd?['lengthSeconds'] as String?) ?? '') ?? 0;
    try {
      final th = (vd?['thumbnail']?['thumbnails'] as List?) ?? const [];
      if (th.isNotEmpty) out['thumbnail'] = th.last['url'];
    } catch (_) {}

    final sd = p['streamingData'] as Map<String, dynamic>?;
    if (sd != null) {
      final hls = sd['hlsManifestUrl'] as String?;
      final prog = ((sd['formats'] as List?) ?? const [])
          .where((f) => f is Map && f['url'] != null)
          .map((f) => {
                'url': f['url'],
                'h': (f['height'] as num?)?.toInt() ?? 0,
              })
          .toList()
        ..sort((a, b) => (b['h']! as int).compareTo(a['h']! as int));
      final aud = ((sd['adaptiveFormats'] as List?) ?? const [])
          .where((f) =>
              f is Map &&
              f['url'] != null &&
              (f['mimeType'] as String? ?? '').startsWith('audio/'))
          .map((f) => {
                'url': f['url'],
                'h': 0,
                'br': (f['bitrate'] as num?)?.toInt() ?? 0,
              })
          .toList()
        ..sort((a, b) => (b['br']! as int).compareTo(a['br']! as int));
      final adaptCount = ((sd['adaptiveFormats'] as List?) ?? const []).length;
      final av = ((sd['adaptiveFormats'] as List?) ?? const [])
          .where((f) =>
              f is Map &&
              f['url'] != null &&
              (f['mimeType'] as String? ?? '').startsWith('video/'))
          .map((f) => {
                'url': f['url'],
                'h': (f['height'] as num?)?.toInt() ?? 0,
              })
          .toList()
        ..sort((a, b) => (b['h']! as int).compareTo(a['h']! as int));
      out['adaptiveVideo'] = av;

      if (hls != null && hls.isNotEmpty) {
        out['media'] = hls;
        out['kind'] = 'youtube-hls';
      } else if (prog.isNotEmpty) {
        out['progressive'] = prog;
        out['kind'] = 'youtube';
      } else if (aud.isNotEmpty) {
        out['audio'] = aud;
        out['kind'] = 'youtube-audio';
      } else {
        out['diag'] = '${out['diag'] ?? ''}|adaptativos:$adaptCount|claves:'
            '${sd.keys.join(",")}';
      }
    } else {
      out['diag'] = '${out['diag'] ?? ''}|sin-streamingData|keys:'
          '${p.keys.take(10).join(",")}';
    }
    return out;
  }

  /// Peticion InnerTube hecha DESDE DART: mismo stack de red que la
  /// descarga (misma IP/familia) - evita el403 por ip= embebido.
  Future<Map<String, dynamic>?> _playerViaDart({
    required String videoId,
    required String key,
    required Map<String, dynamic> client,
  }) async {
    final uri = Uri.parse('https://www.youtube.com/youtubei/v1/player'
        '?prettyPrint=false${key.isEmpty ? '' : '&key=$key'}');
    final body = jsonEncode({
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
      'context': {'client': client},
    });
    final hc = _newHttp(const Duration(seconds: 20));
    try {
      final req = await hc.postUrl(uri);
      req.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.headers.set('User-Agent', ua);
      req.headers.set('Referer', 'https://www.youtube.com/');
      final ck = sessionCookies;
      if (ck != null && ck.isNotEmpty) req.headers.set('Cookie', ck);
      req.write(body);
      final resp = await req.close().timeout(const Duration(seconds: 25));
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        return {'__error': 'player HTTP ${resp.statusCode}'};
      }
      final j = jsonDecode(text);
      if (j is Map<String, dynamic>) return j;
      return {'__error': 'json-invalido'};
    } catch (e) {
      return {'__error': e.toString()};
    } finally {
      hc.close(force: true);
    }
  }

  static const _autoplayJs = r'''
(() => {
  const v = document.querySelector("video");
  if (!v) return "novideo";
  try { v.muted = true; v.defaultMuted = true; v.volume = 0; } catch(e){}
  try { const pr = v.play(); if (pr && pr.catch) pr.catch(() => {}); } catch(e){}
  return "ok";
})()
''';

  static const _readSrcJs =
      r'(()=>{const v=document.querySelector("video");return v ? (v.currentSrc || v.src || "") : "";})()';

  /// JS multi-fuente de extracción (YouTube + video/HLS embebido).
  /// IMPORTANTE: sin comillas simples (va dentro de un string raw de Dart).
  static const _extractJs = r'''
(() => {
  const out = {kind:"none", title:"", thumbnail:"", duration:0, media:"",
               progressive:[], audio:[], diag:""};
  const parseMaybe = (v) => { try { return (typeof v === "string") ? JSON.parse(v) : v; } catch(e) { return null; } };
  const getResp = () => {
    try { if (window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.streamingData) return window.ytInitialPlayerResponse; } catch(e){}
    try { if (window.ytcfg && typeof ytcfg.get === "function") { const r = parseMaybe(ytcfg.get("PLAYER_RESPONSE")); if (r && r.streamingData) return r; } } catch(e){}
    try { if (window.ytplayer && ytplayer.config && ytplayer.config.args) { const a = ytplayer.config.args; const r = parseMaybe(a.raw_player_response || a.player_response); if (r && r.streamingData) return r; } } catch(e){}
    try {
      const sc = Array.from(document.querySelectorAll("script"));
      for (const s of sc) {
        const t = s.textContent || "";
        const i = t.indexOf("ytInitialPlayerResponse");
        if (i < 0) continue;
        const eq = t.indexOf("=", i);
        if (eq < 0) continue;
        let depth = 0, start = -1, inStr = false, esc = false;
        for (let k = eq + 1; k < t.length; k++) {
          const ch = t.charAt(k);
          if (inStr) {
            if (esc) esc = false;
            else if (ch === "\\") esc = true;
            else if (ch === "\"") inStr = false;
            continue;
          }
          if (ch === "\"") { inStr = true; continue; }
          if (ch === "{") { if (depth === 0) start = k; depth++; }
          else if (ch === "}") { depth--; if (depth === 0 && start >= 0) return JSON.parse(t.slice(start, k + 1)); }
        }
      }
    } catch(e){ out.diag += "scriptscan:" + (e && e.message); }
    return null;
  };
  try {
    const p = getResp();
    if (p && p.streamingData) {
      const vd = p.videoDetails || {};
      out.title = vd.title || document.title || "Video";
      try { const th = vd.thumbnail.thumbnails; if (th && th.length) out.thumbnail = th[th.length - 1].url; } catch(e){}
      out.duration = parseInt(vd.lengthSeconds || "0", 10) || 0;
      const prog = (p.streamingData.formats || []).filter(x => x.url);
      prog.sort((a,b) => (b.height||0) - (a.height||0));
      out.progressive = prog.map(x => ({url:x.url, h:x.height||0}));
      const aud = (p.streamingData.adaptiveFormats || []).filter(x => x.url && x.mimeType && x.mimeType.indexOf("audio/") === 0);
      aud.sort((a,b) => (b.bitrate||0) - (a.bitrate||0));
      out.audio = aud.map(x => ({url:x.url, h:0, br:x.bitrate||0}));
      const av = (p.streamingData.adaptiveFormats || []).filter(x => x.url && x.mimeType && x.mimeType.indexOf("video/") === 0);
      av.sort((a,b) => (b.height||0) - (a.height||0));
      out.adaptiveVideo = av.map(x => ({url:x.url, h:x.height||0}));
      out.client = "WEB";
      // iPhone: YouTube sirve HLS (calidad completa con audio) via hlsManifestUrl.
      if (p.streamingData.hlsManifestUrl) {
        out.media = p.streamingData.hlsManifestUrl;
        out.kind = "youtube-hls";
      } else if (out.progressive.length) {
        out.kind = "youtube";
      } else if (out.audio.length) {
        out.kind = "youtube-audio";
      } else {
        out.diag += "|solo-adaptativos:" + ((p.streamingData.adaptiveFormats||[]).length);
      }
    }
  } catch(e){ out.diag += "|resp:" + (e && e.message); }
  if (out.kind === "none") {
    try {
      const v = document.querySelector("video");
      const src = (v && (v.currentSrc || v.src)) || "";
      if (src && src.indexOf("http") === 0) {
        out.media = src;
        out.kind = src.indexOf(".m3u8") >= 0 ? "hls" : "video";
        out.title = out.title || document.title || "Video";
        try { const m = document.querySelector("meta[property=\"og:image\"]"); if (m && m.content) out.thumbnail = m.content; } catch(e){}
      }
    } catch(e){}
  }
  if (out.kind === "none") {
    try {
      const mi = document.querySelector("meta[property=\"og:image\"]");
      if (mi && mi.content) out.thumbnail = mi.content;
      const mt = document.querySelector("meta[property=\"og:title\"]");
      if (mt && mt.content && !out.title) out.title = mt.content;
    } catch(e){}
  }
  try {
    if (window.ytcfg && typeof ytcfg.get === "function") out.key = ytcfg.get("INNERTUBE_API_KEY") || "";
  } catch(e){}
  try {
    let vid = "";
    const m = location.search.match(/v=([A-Za-z0-9_-]{6,})/);
    if (m) vid = m[1];
    if (!vid && location.pathname.indexOf("/shorts/") === 0) vid = location.pathname.split("/")[2] || "";
    if (!vid && window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails) vid = window.ytInitialPlayerResponse.videoDetails.videoId || "";
    out.videoId = vid;
  } catch(e){}
  out.diag += "|url:" + location.href + "|ytipr:" + (typeof window.ytInitialPlayerResponse);
  return JSON.stringify(out);
})()
''';

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
    final client = _newHttp(const Duration(seconds: 20));
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
      'kind': kind == 'HLS' ? 'hls' : 'video',
      'progressive': <Map<String, dynamic>>[],
      'audio': <Map<String, dynamic>>[],
      'page_url': media,
    };
  }

  /// Analiza una página YA CARGADA en el webview oculto de Universal.
  Future<Map<String, dynamic>> analyzeInPage(
      InAppWebViewController controller) async {
    final d = await extractFromPage(controller);
    final kind = (d['kind'] as String?) ?? 'none';
    final prog = (d['progressive'] as List);
    final audio = (d['audio'] as List);
    final rawTitle = (d['title'] as String?) ?? '';
    final title = rawTitle.trim().isEmpty ? 'Video' : rawTitle.trim();
    final pageUrl = (await controller.getUrl())?.toString() ?? '';
    final thumb = d['thumbnail'];

    if (kind == 'youtube' || kind == 'youtube-audio' || kind == 'youtube-hls') {
      final bestH = prog.isNotEmpty
          ? ((prog.first['h'] as num?)?.toInt() ?? 0)
          : 0;
      final String label;
      if (kind == 'youtube-hls') {
        label = 'YouTube HD (HLS)';
      } else if (kind == 'youtube') {
        label = 'YouTube ${bestH}p';
      } else {
        label = 'YouTube (solo audio)';
      }
      return {
        'ok': true,
        'title': title,
        'thumbnail': thumb,
        'duration': (d['duration'] as num?)?.toInt() ?? 0,
        'extractor': label,
        'webpage_url':
            kind == 'youtube-hls' ? (d['media'] ?? pageUrl) : pageUrl,
        'kind': kind,
        'progressive': prog,
        'audio': audio,
        'adaptiveVideo': (d['adaptiveVideo'] as List? ?? const []),
        'client': (d['client'] as String?) ?? 'WEB',
        'page_url': 'https://www.youtube.com/',
      };
    }
    if (kind == 'hls' || kind == 'video') {
      return {
        'ok': true,
        'title': title,
        'thumbnail': thumb,
        'duration': (d['duration'] as num?)?.toInt() ?? 0,
        'extractor': kind == 'hls' ? 'HLS' : 'Directo',
        'webpage_url': d['media'],
        'kind': kind,
        'progressive': <Map<String, dynamic>>[],
        'audio': <Map<String, dynamic>>[],
        'page_url': pageUrl,
      };
    }
    return {
      'ok': false,
      'error': 'La página no expone un video descargable. ${d['diag'] ?? ''}'
    };
  }

  /// Descarga usando lo analizado en la pagina (Universal iOS).
  Future<void> downloadFromAnalyzed({
    required String id,
    required Map<String, dynamic> info,
    required bool audioOnly,
    required int maxHeight,
    InAppWebViewController? controller,
  }) async {
    final kind0 = (info['kind'] as String?) ?? 'video';
    final isYoutube = kind0 == 'youtube' ||
        kind0 == 'youtube-audio' ||
        kind0 == 'youtube-hls';

    // YouTube: misma logica de reintentos anti-403 (URL fresca si la IP
    // del carrier rota entre player y descarga).
    if (isYoutube && controller != null) {
      _canceled[id] = false;
      _emit(EngineEvent(id: id, type: 'start'));
      Object? lastError;
      var data = info;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          _emit(EngineEvent(
              id: id,
              type: 'progress',
              progress: 0,
              message: 'Reintento ${attempt + 1}/3 (IP cambio)'));
          await Future.delayed(const Duration(seconds: 2));
          final fresh = await extractFromPage(controller);
          if ((fresh['kind'] as String?) == 'none') break;
          data = fresh;
        }
        try {
          await _ytDownloadStep(id, data, audioOnly, maxHeight);
          return;
        } catch (e) {
          lastError = e;
          if (!e.toString().contains('403')) break;
        }
      }
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message:
              'Fallo tras reintentos: ${lastError ?? "error desconocido"}'));
      return;
    }

    _canceled[id] = false;
    _emit(EngineEvent(id: id, type: 'start'));
    await _run(id, () async {
      final kind = kind0;
      final title = info['title'] as String?;
      final page = (info['page_url'] as String?) ?? '';
      final clientUa = _uaForClient((info['client'] as String?) ?? 'WEB');

      if (audioOnly) {
        final audio = (info['audio'] as List? ?? const []);
        final prog = (info['progressive'] as List? ?? const []);
        String? url;
        if (audio.isNotEmpty) url = audio.first['url'] as String;
        if (url == null && prog.isNotEmpty) url = prog.first['url'] as String;
        if (url == null) {
          throw Exception('Este video no ofrecio audio en iOS');
        }
        await _downloadDirect(id, url,
            audioOnly: true, title: title, extraHeaders: _ytHeaders(clientUa));
        return;
      }

      final media = (info['webpage_url'] as String?) ?? '';
      if (media.isEmpty) throw Exception('Sin URL de media');
      if (kind == 'hls' || media.contains('.m3u8')) {
        await _downloadHls(id, media,
            title: title, headers: {'User-Agent': clientUa, 'Referer': page});
      } else {
        await _downloadDirect(id, media,
            title: title, headers: {'User-Agent': clientUa, 'Referer': page});
      }
    });
  }

  /// Descarga video y audio (adaptativos por separado) y los une con
  /// ffmpeg-kit en un solo MP4 con audio.
  Future<void> _downloadAdaptiveMerge({
    required String id,
    required String videoUrl,
    required String audioUrl,
    required String? title,
    required String clientUa,
  }) async {
    final dir = await downloadDir();
    final work = Directory('${dir.path}/$id.adapt');
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final vFile = File('${work.path}/video.mp4');
    final aFile = File('${work.path}/audio.m4a');
    final ytHeaders = _ytHeaders(clientUa);

    _emit(EngineEvent(
        id: id, type: 'progress', progress: 0, message: 'Video...'));
    await _downloadToFile(id, videoUrl, vFile,
        headers: ytHeaders, progressFrom: 0, progressTo: 85);
    if (_canceled[id] == true) return;
    _emit(EngineEvent(
        id: id, type: 'progress', progress: 86, message: 'Audio...'));
    await _downloadToFile(id, audioUrl, aFile,
        headers: ytHeaders, progressFrom: 87, progressTo: 98);
    if (_canceled[id] == true) return;

    final safe = (title ?? 'video').replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final joined = '${work.path}/$safe.mp4';
    _emit(EngineEvent(
        id: id, type: 'progress', progress: 99, message: 'Uniendo pistas'));
    final session = await FFmpegKit.execute(
        '-y -i "${vFile.path}" -i "${aFile.path}" -c copy "$joined"');
    final rc = await session.getReturnCode();
    if (rc == null || !ReturnCode.isSuccess(rc)) {
      throw Exception('FFmpeg no pudo unir video y audio (${rc?.getValue()})');
    }
    final outPath = '${dir.path}/$safe.mp4';
    final out = File(outPath);
    if (out.existsSync()) out.deleteSync();
    File(joined).renameSync(outPath);
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
    _emit(EngineEvent(id: id, type: 'done', progress: 100, path: outPath));
  }

  /// Abre el stream de video. Si responde 403 reintenta con
  /// `Range: bytes=0-` (algunos nodos de googlevideo lo exigen).
  /// Devuelve {client, resp, range}.
  Future<Map<String, dynamic>> _openVideo(
      String url, Map<String, String> headers) async {
    Future<Map<String, dynamic>> attempt(bool useRange) async {
      final hc = _newHttp();
      final req = await hc.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', ua);
      headers.forEach((k, v) => req.headers.set(k, v));
      if (useRange) req.headers.add('range', 'bytes=0-');
      final resp = await req.close();
      return {'client': hc, 'resp': resp, 'range': useRange};
    }

    final first = await attempt(false);
    final r1 = first['resp'] as HttpClientResponse;
    if (r1.statusCode == 403) {
      (first['client'] as HttpClient).close(force: true);
      return attempt(true);
    }
    return first;
  }
  /// Descarga un archivo a destino concreto con progreso escalado.
  Future<void> _downloadToFile(
    String id,
    String url,
    File target, {
    Map<String, String>? headers,
    double progressFrom = 0,
    double progressTo = 100,
  }) async {
    final open = await _openVideo(url, headers ?? const {});
    final client = open['client'] as HttpClient;
    final resp = open['resp'] as HttpClientResponse;
    final usedRange = open['range'] == true;
    _clients[id] = client;
    if (resp.statusCode >= 400) {
      String reason = '';
      try {
        final bodyText = await resp
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
        reason = bodyText
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (reason.length > 200) reason = reason.substring(0, 200);
      } catch (_) {}
      // Diagnostico: primera parte de las cabeceras de la respuesta.
      try {
        final hdr = resp.headers.toString();
        // ignore: avoid_print
        print('[VDC403] status=${resp.statusCode} url=${url.substring(0, url.length.clamp(0, 120))} '
            'headers=${hdr.substring(0, hdr.length.clamp(0, 400))}');
      } catch (_) {}      await _refreshPublicIp();
      _lastCookieSent = (headers ?? const {}).containsKey('Cookie');
      client.close(force: true);
      throw Exception(_httpError(resp.statusCode, url) +
          ' | rango:${usedRange ? "si" : "NO"}' +
          (reason.isEmpty ? '' : ' | MOTIVO: $reason'));
    }
    final total = resp.contentLength;
    var received = 0;
    var lastPct = -1.0;
    final sink = target.openWrite();
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
          final frac = received * 100 / total;
          final pct = progressFrom + (progressTo - progressFrom) * frac / 100;
          final rounded = pct.floorToDouble();
          if (rounded != lastPct) {
            lastPct = rounded;
            _emit(EngineEvent(id: id, type: 'progress', progress: rounded));
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
    if (_canceled[id] == true) throw Exception('Cancelado');
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
    final open = await _openVideo(url, headers ?? extraHeaders ?? const {});
    final client = open['client'] as HttpClient;
    final resp = open['resp'] as HttpClientResponse;
    final usedRange = open['range'] == true;
    _clients[id] = client;

    if (resp.statusCode >= 400) {
      String reason = '';
      try {
        final bodyText = await resp
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
        reason = bodyText
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (reason.length > 200) reason = reason.substring(0, 200);
      } catch (_) {}
      await _refreshPublicIp();
      _lastCookieSent = (headers ?? extraHeaders ?? const {}).containsKey('Cookie');
      client.close(force: true);
      _emit(EngineEvent(
          id: id,
          type: 'error',
          message: _httpError(resp.statusCode, url) +
              ' | rango:${usedRange ? "si" : "NO"}' +
              (reason.isEmpty ? '' : ' | MOTIVO: $reason')));
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
    final client = _newHttp();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', ua);
      headers?.forEach((k, v) { req.headers.set(k, v); });
      final resp = await req.close();
      await resp.pipe(file.openWrite());
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _getText(String url, Map<String, String>? headers) async {
    final client = _newHttp();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', ua);
      headers?.forEach((k, v) { req.headers.set(k, v); });
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
