import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/download_item.dart';
import '../services/app_controller.dart';
import '../widgets/gradient_button.dart';

class ConvertTab extends StatefulWidget {
  const ConvertTab({super.key});

  @override
  State<ConvertTab> createState() => _ConvertTabState();
}

class _ConvertTabState extends State<ConvertTab>
    with AutomaticKeepAliveClientMixin {
  String? _pickedPath;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    AppController.instance.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    AppController.instance.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp'],
    );
    final path = files.isNotEmpty ? files.first.path : null;
    if (path == null) return;
    if (!File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No se pudo leer el archivo. En Android, elige uno de la carpeta Download.')));
      }
      return;
    }
    setState(() => _pickedPath = path);
  }

  Future<void> _convert() async {
    final path = _pickedPath;
    if (path == null) return;
    final app = AppController.instance;
    if (app.engineStatus != 'ready') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('El motor de conversión aún no está listo')));
      return;
    }
    setState(() => _busy = true);
    await app.startConvert(path);
    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Conversión iniciada · el MP3 quedará en VideoDownloader')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final app = AppController.instance;
    final scheme = Theme.of(context).colorScheme;
    final conversions =
        app.items.where((i) => i.id.startsWith('cv-')).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(children: [
          const GradientIconBadge(Icons.swap_horiz_rounded),
          const SizedBox(width: 12),
          GradientTitle('Convertir MP4 a MP3'),
        ]),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_pickedPath == null)
                  Center(
                    child: Column(children: [
                      Icon(Icons.video_file_rounded,
                          size: 48, color: scheme.outline),
                      const SizedBox(height: 8),
                      Text('Ningún archivo seleccionado',
                          style: TextStyle(color: scheme.outline)),
                    ]),
                  )
                else ...[
                  Row(children: [
                    Icon(Icons.check_circle_rounded, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pickedPath!.split(Platform.pathSeparator).last,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    _pickedPath!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Elegir video'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GradientButton(
                      onPressed: _pickedPath == null || _busy ? null : _convert,
                      semanticsLabel: 'Convertir a MP3',
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.headphones_rounded),
                                SizedBox(width: 8),
                                Text('A MP3'),
                              ],
                            ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          Platform.isAndroid
              ? 'En Android, elige archivos que estén en la carpeta Download (por límites del sistema).'
              : 'El MP3 resultante se guarda en tu carpeta Descargas\\VideoDownloader.',
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
        const SizedBox(height: 20),
        if (conversions.isNotEmpty) ...[
          Text('Conversiones recientes',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...conversions.map((item) => _ConversionCard(item: item)),
        ],
      ],
    );
  }
}

class _ConversionCard extends StatelessWidget {
  const _ConversionCard({required this.item});
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
            Row(children: [
              Icon(Icons.audio_file_rounded, color: scheme.tertiary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${item.title.replaceAll(RegExp(r'\.[^.]+$'), '')}.mp3',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (running)
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Cancelar',
                  onPressed: () => AppController.instance.cancel(item.id),
                )
              else if (item.status == DownloadStatus.done && item.path != null)
                IconButton(
                  icon: const Icon(Icons.folder_open_rounded),
                  tooltip: 'Abrir ubicación',
                  onPressed: () =>
                      AppController.instance.openFile(item.path!),
                )
              else if (item.status == DownloadStatus.error)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () =>
                      AppController.instance.removeItem(item.id),
                ),
            ]),
            if (running) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: item.progress > 0 ? item.progress / 100 : null,
                borderRadius: BorderRadius.circular(4),
              ),
            ] else if (item.status == DownloadStatus.error) ...[
              Text(item.message ?? 'Error',
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ] else if (item.status == DownloadStatus.done) ...[
              Text('MP3 listo ✓',
                  style: TextStyle(fontSize: 12, color: scheme.primary)),
            ],
          ],
        ),
      ),
    );
  }
}
