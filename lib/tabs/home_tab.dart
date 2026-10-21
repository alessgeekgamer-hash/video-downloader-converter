import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/download_item.dart';
import '../services/app_controller.dart';
import '../widgets/gradient_button.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab>
    with AutomaticKeepAliveClientMixin {
  final _urlCtrl = TextEditingController();
  bool _audioOnly = false;
  int _maxHeight = -1; // -1 = máxima
  String _defaultDir = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    AppController.instance.addListener(_refresh);
    AppController.instance.defaultDownloadDir().then((d) {
      if (mounted) setState(() => _defaultDir = d);
    });
    // Al abrir la app, ofrecer pegar el enlace del portapapeles.
    Clipboard.getData(Clipboard.kTextPlain).then((data) {
      final text = data?.text?.trim() ?? '';
      if (mounted && _urlCtrl.text.isEmpty && _looksLikeUrl(text)) {
        setState(() => _urlCtrl.text = text);
      }
    });
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    AppController.instance.removeListener(_refresh);
    _urlCtrl.dispose();
    super.dispose();
  }

  bool _looksLikeUrl(String t) =>
      t.startsWith('http') && (t.contains('youtu') || t.contains('tiktok'));

  String _shortPath(String p) {
    final parts = p.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
    if (parts.length <= 3) return p;
    return '.../${parts.sublist(parts.length - 2).join('/')}';
  }

  Future<void> _download() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Pega primero un enlace de YouTube o TikTok')));
      return;
    }
    // En iOS YouTube/TikTok/Cualquier sitio se descargan desde la
    // pestaña Universal (lee el video de la página con su navegador)
    // o desde la pestaña del sitio correspondiente.
    if (Platform.isIOS) {
      final u = url.toLowerCase();
      if (u.contains('youtu')) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'En iOS: pega el enlace en la pestaña Universal (analiza el video) o ábrelo en YouTube y usa Descargar')));
        return;
      }
      if (u.contains('tiktok')) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'En iOS: abre el video en la pestaña TikTok y usa su botón Descargar')));
        return;
      }
    }
    final app = AppController.instance;
    if (app.engineStatus != 'ready') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('El motor de descarga aún no está listo')));
      return;
    }
    await app.startDownload(
      url: url,
      audioOnly: _audioOnly,
      maxHeight: _maxHeight,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_audioOnly
            ? 'Descarga iniciada (MP3)'
            : 'Descarga iniciada (MP4)'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final app = AppController.instance;
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _EngineBanner(app: app),
        const SizedBox(height: 12),
        Row(
          children: [
            const GradientIconBadge(Icons.cloud_download_rounded),
            const SizedBox(width: 12),
            GradientTitle('Descargar video'),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlCtrl,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: 'https://www.youtube.com/watch?v=...',
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
        LayoutBuilder(builder: (context, constraints) {
          // En pantallas angostas (720p) se apilan para que no se partan
          // las etiquetas MP4/MP3.
          final controls = [
            SegmentedButton<bool>(
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
              onSelectionChanged: (s) => setState(() => _audioOnly = s.first),
            ),
            DropdownButtonFormField<int>(
              initialValue: _maxHeight,
              decoration: const InputDecoration(
                  labelText: 'Calidad', prefixIcon: Icon(Icons.hd_rounded)),
              items: const [
                DropdownMenuItem(value: -1, child: Text('Máxima')),
                DropdownMenuItem(value: 1080, child: Text('1080p')),
                DropdownMenuItem(value: 720, child: Text('720p')),
                DropdownMenuItem(value: 480, child: Text('480p')),
                DropdownMenuItem(value: 360, child: Text('360p')),
              ],
              onChanged:
                  _audioOnly ? null : (v) => setState(() => _maxHeight = v ?? -1),
            ),
          ];
          if (constraints.maxWidth < 380) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                controls.first,
                const SizedBox(height: 12),
                controls.last,
              ],
            );
          }
          return Row(children: [
            Expanded(child: controls.first),
            const SizedBox(width: 12),
            Expanded(child: controls.last),
          ]);
        }),
        const SizedBox(height: 12),
        GradientButton(
          onPressed: _download,
          semanticsLabel: 'Descargar',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.download_rounded),
              SizedBox(width: 8),
              Text('Descargar'),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Carpeta de descargas
        Card(
          child: ListTile(
            leading: Icon(Icons.folder_rounded, color: scheme.tertiary),
            title: const Text('Carpeta de descargas',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              app.downloadFolder != null
                  ? _shortPath(app.downloadFolder!)
                  : (_defaultDir.isEmpty
                      ? 'Predeterminada'
                      : _shortPath(_defaultDir)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (app.downloadFolder != null)
                  IconButton(
                    tooltip: 'Usar carpeta predeterminada',
                    icon: const Icon(Icons.restart_alt_rounded),
                    onPressed: () => app.resetDownloadFolder(),
                  ),
                IconButton(
                  tooltip: 'Elegir carpeta',
                  icon: const Icon(Icons.folder_open_rounded),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final ok = await app.pickFolder();
                    if (ok) {
                      messenger.showSnackBar(const SnackBar(
                          content: Text('Carpeta de descargas actualizada')));
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('Descargas',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            if (app.items.any((i) => i.status != DownloadStatus.running))
              TextButton.icon(
                onPressed: () => app.clearFinished(),
                icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                label: const Text('Limpiar'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (app.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('Aún no hay descargas',
                  style: TextStyle(color: scheme.outline)),
            ),
          ),
        ...app.items.map((item) => _DownloadCard(item: item)),
      ],
    );
  }
}

class _EngineBanner extends StatelessWidget {
  const _EngineBanner({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (app.engineStatus) {
      case 'loading':
        return Card(
          child: ListTile(
            leading: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            title: const Text('Preparando el motor de descarga...'),
            subtitle: const Text('Incluye yt-dlp y FFmpeg embebidos'),
          ),
        );
      case 'error':
        return Card(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.error_outline_rounded,
                      color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('Motor no disponible',
                          style: TextStyle(
                              color: scheme.onErrorContainer,
                              fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 4),
                Text(app.engineError,
                    style: TextStyle(
                        color: scheme.onErrorContainer, fontSize: 12)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => app.reinit(),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        );
      default:
        return Card(
          child: ListTile(
            leading: Icon(Icons.check_circle_rounded, color: scheme.primary),
            title: Text(() {
              final v = app.engineVersion
                  .replaceAll(RegExp(r'\s*null$'), '')
                  .trim();
              return v.isEmpty ? 'Motor listo' : 'Motor listo · $v';
            }()),
            subtitle: const Text(
                'Toca y mantén un video en YouTube/TikTok para copiar su enlace, o usa el botón ⬇ en el navegador'),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) async {
                if (v == 'update') {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.showSnackBar(
                      const SnackBar(content: Text('Actualizando motor...')));
                  final msg = await app.updateEngine();
                  messenger.showSnackBar(SnackBar(content: Text(msg)));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'update',
                    child: ListTile(
                        leading: Icon(Icons.system_update_rounded),
                        title: Text('Actualizar motor (yt-dlp)'))),
              ],
            ),
          ),
        );
    }
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.item});
  final DownloadItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = item.status == DownloadStatus.running;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  item.audioOnly
                      ? Icons.headphones_rounded
                      : Icons.videocam_rounded,
                  color: item.audioOnly ? scheme.tertiary : scheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (running)
                  IconButton(
                    tooltip: 'Cancelar',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => AppController.instance.cancel(item.id),
                  )
                else if (item.path != null)
                  IconButton(
                    tooltip: 'Abrir ubicación',
                    icon: const Icon(Icons.folder_open_rounded),
                    onPressed: () =>
                        AppController.instance.openFile(item.path!),
                  ),
                if (!running)
                  IconButton(
                    tooltip: 'Quitar de la lista',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () =>
                        AppController.instance.removeItem(item.id),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (running) ...[
              LinearProgressIndicator(
                value: item.progress > 0 ? item.progress / 100 : null,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 4),
              Text(
                item.progress > 0
                    ? '${item.progress.toStringAsFixed(1)} %'
                    : 'Iniciando...',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ] else if (item.status == DownloadStatus.error) ...[
              Text(
                item.message ?? 'Error',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ] else ...[
              Row(children: [
                Icon(Icons.check_circle_rounded,
                    size: 16, color: scheme.primary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    item.path ?? 'Completado',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
