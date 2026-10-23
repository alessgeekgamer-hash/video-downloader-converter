import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/app_controller.dart';
import '../services/download_service.dart';
import '../services/ios_engine.dart';
import '../widgets/gradient_button.dart';

/// Pestaña de navegación reutilizable para YouTube y TikTok, con botón
/// de descarga del video mostrado en la página actual.
class WebTab extends StatefulWidget {
  const WebTab({
    super.key,
    required this.title,
    required this.icon,
    required this.initialUrl,
    required this.onOpenDownloads,
    this.active = true,
  });

  final String title;
  final IconData icon;
  final String initialUrl;
  final VoidCallback onOpenDownloads;

  /// Indica si esta pestaña es la visible. Al pasar a false se pausa
  /// el audio/video para que no se escuche desde otras pestañas.
  final bool active;

  @override
  State<WebTab> createState() => _WebTabState();
}

class _WebTabState extends State<WebTab> with AutomaticKeepAliveClientMixin {
  InAppWebViewController? _controller;
  PullToRefreshController? _pullToRefresh;
  String? _currentUrl;
  String? _loadError;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

  // iOS: último stream .m3u8 visto (TikTok reproduce HLS).
  String? _lastStreamUrl;
  String? _lastStreamPage;

  @override
  bool get wantKeepAlive => true;

  // UA de Chrome actual SIN ";wv" para que el sitio lo vea como Chrome
  // normal (permite iniciar sesión con Google y evita marcarlo como bot).
  static const _chromeAndroidUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36';

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _pullToRefresh = PullToRefreshController(
        onRefresh: () => _controller?.reload(),
      );
    }
    // ignore: avoid_print
    print('[WEB ${widget.title}] iniciando pestaña: ${widget.initialUrl}');
  }

  @override
  void didUpdateWidget(covariant WebTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Al dejar de ser la pestaña visible, pausar todo el multimedia
    // para que el sonido no se escuche en las demás pestañas.
    if (oldWidget.active && !widget.active) _pauseMedia();
  }

  void _pauseMedia() {
    // ignore: avoid_print
    print('[WEB ${widget.title}] pestaña oculta: multimedia en pausa');
    _controller?.evaluateJavascript(
      source: "(() => { try { document.querySelectorAll('video,audio')"
          ").forEach(v => { try { v.pause(); } catch (e) {} }); } catch (e) {} })();",
    );
    _pullToRefresh?.endRefreshing();
  }

  void _syncNavState() async {
    final c = _controller;
    if (c == null) return;
    final back = await c.canGoBack();
    final forward = await c.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  void _setError(String message) {
    if (!mounted || _loadError == message) return;
    // ignore: avoid_print
    print('[WEB ${widget.title}] ERROR: $message');
    setState(() => _loadError = message);
    _pullToRefresh?.endRefreshing();
  }

  void _retry() {
    setState(() => _loadError = null);
    _pullToRefresh?.beginRefreshing();
    _controller?.reload();
  }

  void _openDownloadSheet() {
    final url = _currentUrl ?? widget.initialUrl;
    bool audioOnly = false;
    int maxHeight = -1;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                GradientIconBadge(widget.icon, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: GradientTitle('Descargar de ${widget.title}',
                      style: Theme.of(sheetContext).textTheme.titleMedium),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.outline),
              ),
              if (AppController.instance.downloadFolder != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Se guarda en: ${AppController.instance.downloadFolder}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                      value: false,
                      icon: Icon(Icons.videocam_rounded),
                      label: Text('Video MP4')),
                  ButtonSegment(
                      value: true,
                      icon: Icon(Icons.headphones_rounded),
                      label: Text('Audio MP3')),
                ],
                selected: {audioOnly},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setSheetState(() => audioOnly = s.first),
              ),
              const SizedBox(height: 12),
              if (!audioOnly)
                DropdownButtonFormField<int>(
                  initialValue: maxHeight,
                  decoration: const InputDecoration(
                      labelText: 'Calidad máxima',
                      prefixIcon: Icon(Icons.hd_rounded)),
                  items: const [
                    DropdownMenuItem(value: -1, child: Text('Máxima')),
                    DropdownMenuItem(value: 1080, child: Text('1080p')),
                    DropdownMenuItem(value: 720, child: Text('720p')),
                    DropdownMenuItem(value: 480, child: Text('480p')),
                    DropdownMenuItem(value: 360, child: Text('360p')),
                  ],
                  onChanged: (v) => setSheetState(() => maxHeight = v ?? -1),
                ),
              const SizedBox(height: 16),
              GradientButton(
                semanticsLabel:
                    audioOnly ? 'Descargar MP3' : 'Descargar MP4',
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  final controller = _controller;
                  final engine = DownloadService.instance;
                  if (Platform.isIOS &&
                      controller != null &&
                      engine is IosEngine) {
                    // iOS: extraer la fuente del video desde la propia página
                    // y llevar las cookies de la sesión (YouTube logueado).
                    await engine.loadCookies(controller);
                    AppController.instance.runDownload(
                      title: 'Video de ${widget.title}',
                      audioOnly: audioOnly,
                      sourceUrl: _currentUrl ?? widget.initialUrl,
                      runner: (id) => engine.downloadFromWebTab(
                        id: id,
                        controller: controller,
                        audioOnly: audioOnly,
                        maxHeight: maxHeight,
                        fallbackStreamUrl: _lastStreamUrl,
                        fallbackPageUrl: _lastStreamPage ?? _currentUrl,
                      ),
                    );
                  } else {
                    AppController.instance.startDownload(
                      url: url,
                      audioOnly: audioOnly,
                      maxHeight: maxHeight,
                    );
                  }
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: const Text('Descarga iniciada'),
                    action: SnackBarAction(
                      label: 'Ver descargas',
                      onPressed: widget.onOpenDownloads,
                    ),
                  ));
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.download_rounded),
                    const SizedBox(width: 8),
                    Text(audioOnly ? 'Descargar MP3' : 'Descargar MP4'),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Consejo: si el enlace es de una lista, primero abre el video que quieres.',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;

    final settings = InAppWebViewSettings(
      userAgent: Platform.isAndroid ? _chromeAndroidUa : null,
      // Necesario para interceptar saltos a esquemas de app (snssdk1233://...).
      useShouldOverrideUrlLoading: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsBackForwardNavigationGestures: true,
      javaScriptEnabled: true,
      domStorageEnabled: true,
      useWideViewPort: true,
      loadWithOverviewMode: true,
      supportMultipleWindows: true,
      cacheEnabled: true,
      thirdPartyCookiesEnabled: true,
      clearCache: false,
    );

    return Column(
      children: [
        Material(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Atrás',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed:
                      _canGoBack ? () => _controller?.goBack() : null,
                ),
                IconButton(
                  tooltip: 'Adelante',
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: _canGoForward
                      ? () => _controller?.goForward()
                      : null,
                ),
                IconButton(
                  tooltip: 'Recargar',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () {
                    setState(() => _loadError = null);
                    _pullToRefresh?.beginRefreshing();
                    _controller?.reload();
                  },
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: .4),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.public_rounded,
                            size: 14, color: scheme.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _currentUrl ?? widget.initialUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: scheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _openDownloadSheet,
                  icon: const Icon(Icons.download_rounded, size: 20),
                  label: const Text('Descargar'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.secondary,
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
        if (_progress < 1)
          LinearProgressIndicator(
            value: _progress > 0 ? _progress : null,
            minHeight: 2.5,
          ),
        Expanded(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(widget.initialUrl),
                  headers: const {
                    'Accept-Language': 'es-MX,es;q=0.9,en;q=0.8'
                  },
                ),
                initialSettings: settings,
                pullToRefreshController: _pullToRefresh,
                onWebViewCreated: (c) {
                  _controller = c;
                  // ignore: avoid_print
                  print('[WEB ${widget.title}] WebView creada');
                },
                onLoadStart: (c, url) {
                  // ignore: avoid_print
                  print('[WEB ${widget.title}] cargando: $url');
                  setState(() {
                    _currentUrl = url?.toString();
                    _loadError = null;
                    _syncNavState();
                  });
                },
                onLoadStop: (c, url) {
                  // ignore: avoid_print
                  print('[WEB ${widget.title}] listo: $url');
                  setState(() => _currentUrl = url?.toString());
                  _syncNavState();
                  _pullToRefresh?.endRefreshing();
                },
                onProgressChanged: (c, progress) =>
                    setState(() => _progress = progress / 100),
                // iOS: capturar streams .m3u8 del reproductor (TikTok HLS).
                onLoadResource: Platform.isIOS
                    ? (c, resource) {
                        final u = resource.url?.toString() ?? '';
                        if (u.contains('.m3u8') ||
                            (u.contains('googlevideo.com') &&
                                u.contains('videoplayback'))) {
                          _lastStreamUrl = u;
                          _lastStreamPage = _currentUrl;
                        }
                      }
                    : null,
                // Las ventanas emergentes (como el inicio de sesión de Google)
                // se cargan en la misma pestaña para no perderlas.
                onCreateWindow: Platform.isAndroid
                    ? (c, createWindowAction) async {
                        final url =
                            createWindowAction.request.url?.toString();
                        if (url != null && url.startsWith('http')) {
                          c.loadUrl(
                              urlRequest: URLRequest(url: WebUri(url)));
                        }
                        return true;
                      }
                    : null,
                onReceivedHttpError: (c, request, response) {
                  final code = response.statusCode ?? 0;
                  if (request.isForMainFrame == true && code >= 400) {
                    _setError(code == 403 || code == 429
                        ? 'El sitio rechazó la carga (HTTP $code)'
                        : 'El sitio respondió con error HTTP $code');
                  }
                },
                onReceivedError: (c, request, error) {
                  final desc = error.description;
                  final up = desc.toUpperCase();
                  // No son errores reales de carga: abortaciones normales y
                  // saltos a esquemas de app (TikTok intenta abrir su app con
                  // snssdk1233://, que WebView no entiende).
                  if (up.contains('ABORTED') ||
                      up.contains('UNKNOWN_URL_SCHEME')) {
                    return;
                  }
                  if (request.isForMainFrame == true) {
                    _setError('No se pudo cargar la página ($desc)');
                  }
                },
                // Bloquea navegaciones a esquemas que no sean http(s):
                // snssdk1233:// (TikTok), tiktok://, intent://, etc. Sin esto,
                // TikTok reemplaza la página con un error y "no abre".
                shouldOverrideUrlLoading: (c, action) async {
                  final url = action.request.url?.toString() ?? '';
                  if (!url.startsWith('http')) {
                    // ignore: avoid_print
                    print('[WEB ${widget.title}] esquema bloqueado: '
                        '${url.split('?').first}');
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onReceivedServerTrustAuthRequest: (c, challenge) async {
                  // Confianza estándar del navegador.
                  return ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.PROCEED);
                },
              ),
              if (_loadError != null)
                Positioned.fill(
                  child: Container(
                    color: scheme.surface,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Card(
                          margin: const EdgeInsets.all(24),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.wifi_off_rounded,
                                    size: 44, color: scheme.secondary),
                                const SizedBox(height: 12),
                                Text(
                                  'No se pudo cargar ${widget.title}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _loadError!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.outline),
                                ),
                                const SizedBox(height: 16),
                                GradientButton(
                                  onPressed: _retry,
                                  semanticsLabel: 'Reintentar',
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.refresh_rounded),
                                      SizedBox(width: 8),
                                      Text('Reintentar'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
