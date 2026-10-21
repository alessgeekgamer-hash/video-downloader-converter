import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_controller.dart';
import '../services/download_service.dart';
import '../services/ios_engine.dart';
import '../widgets/gradient_button.dart';

/// Pestaña (solo Windows) para descargar videos de CUALQUIER sitio
/// pegando la URL: analiza la página con yt-dlp y muestra el video.
class ExtractTab extends StatefulWidget {
  const ExtractTab({
    super.key,
    required this.onOpenDownloads,
    this.initialUrl,
  });

  final VoidCallback onOpenDownloads;

  /// Si la app se lanza con una URL (ej. doble clic en un enlace),
  /// se precarga y se analiza automáticamente.
  final String? initialUrl;

  @override
  State<ExtractTab> createState() => _ExtractTabState();
}

class _ExtractTabState extends State<ExtractTab>
    with AutomaticKeepAliveClientMixin {
  final _urlCtrl = TextEditingController();
  bool _loading = false;
  bool _downloading = false;
  String? _error;
  Map<String, dynamic>? _info;
  bool _audioOnly = false;
  int _maxHeight = -1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final url = widget.initialUrl;
    if (url != null && url.startsWith('http')) {
      _urlCtrl.text = url;
      WidgetsBinding.instance.addPostFrameCallback((_) => _analyze());
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      setState(() => _error = 'Pega una URL que empiece con http:// o https://');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    final engine = DownloadService.instance;
    Map<String, dynamic> res;
    if (engine is WindowsEngine) {
      res = await engine.analyze(url);
    } else if (engine is IosEngine) {
      res = await engine.analyzeUniversal(url);
    } else {
      res = {'ok': false, 'error': 'No disponible en esta plataforma'};
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['ok'] == true) {
        _info = res;
      } else {
        _error = res['error'] as String? ?? 'No se pudo analizar la URL';
      }
    });
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null) return;
    setState(() => _downloading = true);
    await AppController.instance.startDownload(
      url: info['webpage_url'] as String,
      audioOnly: _audioOnly,
      maxHeight: _maxHeight,
    );
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Descarga iniciada'),
      action: SnackBarAction(
        label: 'Ver descargas',
        onPressed: widget.onOpenDownloads,
      ),
    ));
  }

  String _fmtDuration(int seconds) {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h h ${m.toString().padLeft(2, '0')} min';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final info = _info;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(children: [
          const GradientIconBadge(Icons.travel_explore_rounded),
          const SizedBox(width: 12),
          Expanded(child: GradientTitle('Descargar de cualquier sitio')),
        ]),
        const SizedBox(height: 8),
        Text(
          'Pega la URL de un video en internet y la app lo busca y lo '
          'descarga. Compatible con la mayoría de sitios: Twitter/X, '
          'Instagram, Facebook, Twitch, Vimeo, Telegram, Reddit y más.',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlCtrl,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: 'https://ejemplo.com/video/123',
            prefixIcon: const Icon(Icons.link_rounded),
            suffixIcon: IconButton(
              tooltip: 'Pegar',
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) _urlCtrl.text = data!.text!.trim();
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        GradientButton(
          onPressed: _loading ? null : _analyze,
          semanticsLabel: 'Buscar video',
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_rounded),
                    SizedBox(width: 8),
                    Text('Buscar video'),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_error!,
                      style: TextStyle(color: scheme.onErrorContainer)),
                ),
              ]),
            ),
          ),
        if (info != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 168,
                          height: 95,
                          child: info['thumbnail'] != null
                              ? Image.network(
                                  info['thumbnail'] as String,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      _thumbPlaceholder(scheme),
                                )
                              : _thumbPlaceholder(scheme),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              info['title'] as String,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            Wrap(spacing: 8, runSpacing: 6, children: [
                              Chip(
                                avatar: Icon(Icons.public_rounded,
                                    size: 15, color: scheme.primary),
                                label: Text(info['extractor'] as String,
                                    style: const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              if (_fmtDuration(info['duration'] as int)
                                  .isNotEmpty)
                                Chip(
                                  avatar: Icon(Icons.schedule_rounded,
                                      size: 15, color: scheme.secondary),
                                  label: Text(
                                      _fmtDuration(info['duration'] as int),
                                      style: const TextStyle(fontSize: 11)),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(children: [
                    Expanded(
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                              value: false,
                              icon: Icon(Icons.videocam_rounded),
                              label: Text('MP4')),
                          ButtonSegment(
                              value: true,
                              icon: Icon(Icons.headphones_rounded),
                              label: Text('MP3')),
                        ],
                        selected: {_audioOnly},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) =>
                            setState(() => _audioOnly = s.first),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _maxHeight,
                        decoration: const InputDecoration(
                            labelText: 'Calidad',
                            prefixIcon: Icon(Icons.hd_rounded)),
                        items: const [
                          DropdownMenuItem(value: -1, child: Text('Máxima')),
                          DropdownMenuItem(value: 1080, child: Text('1080p')),
                          DropdownMenuItem(value: 720, child: Text('720p')),
                          DropdownMenuItem(value: 480, child: Text('480p')),
                          DropdownMenuItem(value: 360, child: Text('360p')),
                        ],
                        onChanged: _audioOnly
                            ? null
                            : (v) => setState(() => _maxHeight = v ?? -1),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  GradientButton(
                    onPressed: _downloading ? null : _download,
                    semanticsLabel:
                        _audioOnly ? 'Descargar MP3' : 'Descargar MP4',
                    child: _downloading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.download_rounded),
                              const SizedBox(width: 8),
                              Text(_audioOnly
                                  ? 'Descargar MP3'
                                  : 'Descargar MP4'),
                            ],
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'La descarga aparece en la pestaña Inicio.',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _thumbPlaceholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.videocam_off_rounded, color: scheme.outline),
      );
}
