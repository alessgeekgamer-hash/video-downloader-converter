import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'ios_engine.dart';

/// Evento emitido por el motor nativo (Android) o por el proceso (Windows).
class EngineEvent {
  final String id;
  final String type; // start | progress | done | error
  final double progress;
  final int eta;
  final String? message;
  final String? path;

  EngineEvent({
    required this.id,
    required this.type,
    this.progress = 0,
    this.eta = 0,
    this.message,
    this.path,
  });
}

/// Abstracción del motor de descarga. En Android usa yt-dlp embebido
/// (librería youtubedl-android) vía MethodChannel; en Windows ejecuta
/// yt-dlp.exe y ffmpeg.exe incluidos junto al ejecutable.
abstract class DownloadService {
  static DownloadService get instance {
    if (Platform.isWindows) return WindowsEngine();
    if (Platform.isIOS) return IosEngine.instance;
    return AndroidEngine();
  }

  Future<Map<String, dynamic>> initEngine();

  /// En Android puede pedir permiso de almacenamiento (requiere
  /// "Archivos y contenido" en Android 11+). En Windows no hace nada.
  Future<bool> ensureStorage();

  Stream<EngineEvent> get events;

  Future<void> startDownload({
    required String id,
    required String url,
    required bool audioOnly,
    required int maxHeight, // -1 = máxima calidad
    String? folder, // carpeta personalizada; null = predeterminada
  });

  Future<void> cancel(String id);

  /// Abre el selector de carpetas del sistema. Devuelve la ruta elegida
  /// o null si el usuario canceló.
  Future<String?> pickDirectory();

  Future<String> updateEngine();

  /// Abre un archivo con el visor del sistema.
  Future<void> openFile(String path);

  /// Directorio donde se guardan las descargas.
  Future<Directory> downloadDir();
}

// ---------------------------------------------------------------------------
// Android
// ---------------------------------------------------------------------------

class AndroidEngine implements DownloadService {
  static const _channel = MethodChannel('vdc/engine');
  static const _events = EventChannel('vdc/progress');

  final _controller = StreamController<EngineEvent>.broadcast();
  bool _listening = false;

  @override
  Stream<EngineEvent> get events {
    if (!_listening) {
      _listening = true;
      _events.receiveBroadcastStream().listen((raw) {
        final m = Map<String, dynamic>.from(raw as Map);
        _controller.add(EngineEvent(
          id: m['id'] as String? ?? '',
          type: m['type'] as String? ?? 'progress',
          progress: (m['progress'] as num?)?.toDouble() ?? 0,
          eta: (m['eta'] as num?)?.toInt() ?? 0,
          message: m['message'] as String?,
          path: m['path'] as String?,
        ));
      }, onError: (_) {});
    }
    return _controller.stream;
  }

  @override
  Future<Map<String, dynamic>> initEngine() async {
    try {
      final res = await _channel.invokeMethod('init');
      return Map<String, dynamic>.from(res as Map);
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.message ?? e.code};
    } on MissingPluginException {
      return {'ok': false, 'error': 'Canal nativo no disponible'};
    }
  }

  @override
  Future<bool> ensureStorage() async {
    try {
      final res = await _channel.invokeMethod('ensureStorage');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startDownload({
    required String id,
    required String url,
    required bool audioOnly,
    required int maxHeight,
    String? folder,
  }) async {
    await _channel.invokeMethod('download', {
      'id': id,
      'url': url,
      'audioOnly': audioOnly,
      'maxHeight': maxHeight,
      'folder': folder,
    });
  }

  @override
  Future<String?> pickDirectory() async {
    try {
      final res = await _channel.invokeMethod('pickDirectory');
      return res as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> cancel(String id) => _channel.invokeMethod('cancel', {'id': id});

  @override
  Future<String> updateEngine() async {
    try {
      await _channel.invokeMethod('updateEngine');
      return 'Motor actualizado';
    } catch (e) {
      return 'Error al actualizar: $e';
    }
  }

  @override
  Future<void> openFile(String path) =>
      _channel.invokeMethod('openFile', {'path': path});

  @override
  Future<Directory> downloadDir() async {
    final res = await _channel.invokeMethod('downloadDir');
    return Directory(res as String);
  }
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

class WindowsEngine implements DownloadService {
  final _controller = StreamController<EngineEvent>.broadcast();
  final Map<String, Process> _procs = {};

  String get _appDir => File(Platform.resolvedExecutable).parent.path;
  String get _ytdlp => '$_appDir\\yt-dlp.exe';
  String get _ffmpegDir => _appDir;

  @override
  Stream<EngineEvent> get events => _controller.stream;

  void _emit(EngineEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  @override
  Future<Map<String, dynamic>> initEngine() async {
    try {
      if (!File(_ytdlp).existsSync()) {
        return {
          'ok': false,
          'error':
              'No se encontró yt-dlp.exe junto al ejecutable. Vuelve a instalar la aplicación.'
        };
      }
      final r = await Process.run(_ytdlp, ['--version']);
      final v = (r.stdout as String).trim();
      return {'ok': true, 'version': v.isEmpty ? 'yt-dlp' : 'yt-dlp $v'};
    } catch (e) {
      return {'ok': false, 'error': 'No se pudo iniciar yt-dlp: $e'};
    }
  }

  @override
  Future<bool> ensureStorage() async => true;

  @override
  Future<Directory> downloadDir() async {
    final profile = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$profile\\Downloads\\VideoDownloader');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  @override
  Future<void> startDownload({
    required String id,
    required String url,
    required bool audioOnly,
    required int maxHeight,
    String? folder,
  }) async {
    final dir = (folder != null && folder.isNotEmpty)
        ? Directory(folder)
        : await downloadDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final args = <String>[
      '--no-mtime',
      '--newline',
      '--no-playlist',
      '--concurrent-fragments',
      '4',
      '--ffmpeg-location',
      _ffmpegDir,
      '-o',
      '${dir.path}\\%(title)s.%(ext)s',
    ];
    if (audioOnly) {
      args.addAll(['-x', '--audio-format', 'mp3', '--audio-quality', '0']);
    } else {
      final h = maxHeight > 0 ? '[height<=$maxHeight]' : '';
      args.addAll([
        '-f',
        'bv*$h[ext=mp4]+ba[ext=m4a]/b$h[ext=mp4]/bv*$h+ba/$h/b',
        '--merge-output-format',
        'mp4',
      ]);
    }
    args.add(url);

    final proc = await Process.start(_ytdlp, args, runInShell: false);
    _procs[id] = proc;
    _emit(EngineEvent(id: id, type: 'start'));

    String? lastDest;
    String? finalPath;
    final outBuf = StringBuffer();

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        outBuf.writeln(line);
        final p = _parseProgress(line);
        if (p != null) {
          _emit(EngineEvent(id: id, type: 'progress', progress: p));
        }
        final d = _parseDestination(line);
        if (d != null) lastDest = d;
        final m = _parseMerged(line);
        if (m != null) finalPath = m;
        if (line.contains('has already been downloaded')) {
          final re = RegExp(r'^(.+?) has already been downloaded');
          final mm = re.firstMatch(line.trim());
          if (mm != null) finalPath = mm.group(1)!.trim();
        }
      },
    );
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        outBuf.writeln(line);
        final p = _parseProgress(line);
        if (p != null) {
          _emit(EngineEvent(id: id, type: 'progress', progress: p));
        }
      },
    );

    final code = await proc.exitCode;
    _procs.remove(id);
    if (code == 0) {
      final extractAudio = _parseExtractAudio(outBuf.toString());
      _emit(EngineEvent(
        id: id,
        type: 'done',
        progress: 100,
        path: extractAudio ?? finalPath ?? lastDest,
      ));
    } else {
      _emit(EngineEvent(
        id: id,
        type: 'error',
        message: code == 1
            ? 'yt-dlp terminó con error (puede que YouTube haya cambiado; actualiza el motor)'
            : 'Error de yt-dlp (código $code)',
      ));
    }
  }

  double? _parseProgress(String line) {
    final m = RegExp(r'\[download\]\s+([\d.]+)%').firstMatch(line);
    if (m != null) return double.tryParse(m.group(1)!);
    return null;
  }

  String? _parseDestination(String line) {
    final m = RegExp(r'Destination: (.+)$').firstMatch(line);
    return m?.group(1)?.trim();
  }

  String? _parseMerged(String line) {
    final m = RegExp(r'Merging formats into "(.+)"').firstMatch(line);
    return m?.group(1)?.trim();
  }

  String? _parseExtractAudio(String out) {
    final all = RegExp(r'ExtractAudio\] Destination: (.+)$')
        .allMatches(out)
        .toList();
    if (all.isNotEmpty) return all.last.group(1)?.trim();
    return null;
  }

  @override
  Future<String?> pickDirectory() async {
    try {
      return await FilePicker.getDirectoryPath(
          dialogTitle: 'Elegir carpeta de descargas');
    } catch (_) {
      return null;
    }
  }

  /// Analiza una URL de cualquier sitio y extrae los datos del video
  /// (título, miniatura, duración) usando yt-dlp. Para la pestaña Universal.
  Future<Map<String, dynamic>> analyze(String url) async {
    try {
      final r = await Process.run(_ytdlp, [
        '--dump-single-json',
        '--no-playlist',
        '--no-warnings',
        '--skip-download',
        url,
      ]).timeout(const Duration(seconds: 90));
      if (r.exitCode != 0) {
        final err = ((r.stderr as String?) ?? '').trim();
        return {
          'ok': false,
          'error': err.isEmpty
              ? 'No se encontró ningún video en esa URL'
              : _firstErrorLine(err),
        };
      }
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      return {
        'ok': true,
        'title': (j['title'] as String?) ?? 'Video',
        'thumbnail': j['thumbnail'],
        'duration': ((j['duration'] as num?) ?? 0).toInt(),
        'extractor': (j['extractor_key'] as String?) ??
            (j['extractor'] as String?) ??
            'Sitio web',
        'webpage_url': (j['webpage_url'] as String?) ?? url,
      };
    } on TimeoutException {
      return {'ok': false, 'error': 'El sitio tardó demasiado en responder'};
    } catch (e) {
      return {'ok': false, 'error': 'No se pudo analizar la URL'};
    }
  }

  String _firstErrorLine(String err) {
    final line = err.split('\n').firstWhere((l) => l.trim().isNotEmpty,
        orElse: () => 'No se pudo descargar de ese sitio');
    return line.length > 160 ? '${line.substring(0, 160)}…' : line;
  }

  @override
  Future<void> cancel(String id) async {
    final p = _procs.remove(id);
    if (p != null) {
      p.kill();
      _emit(EngineEvent(id: id, type: 'error', message: 'Cancelado'));
    }
  }

  @override
  Future<String> updateEngine() async {
    try {
      if (!File(_ytdlp).existsSync()) return 'yt-dlp.exe no encontrado';
      final r = await Process.run(_ytdlp, ['-U']);
      if (r.exitCode == 0) return 'Motor actualizado correctamente';
      return 'Actualización terminada con avisos';
    } catch (e) {
      return 'Error al actualizar: $e';
    }
  }

  @override
  Future<void> openFile(String path) async {
    if (!File(path).existsSync()) return;
    await Process.start(
      'explorer.exe',
      ['/select,', path],
      mode: ProcessStartMode.detached,
    );
  }

  /// Convierte un archivo local a MP3 usando ffmpeg.exe.
  Future<void> convertLocal(String id, String inputPath, String? folder) async {
    final file = File(inputPath);
    if (!file.existsSync()) {
      _emit(EngineEvent(
          id: id, type: 'error', message: 'Archivo no encontrado'));
      return;
    }
    final dir = (folder != null && folder.isNotEmpty)
        ? Directory(folder)
        : await downloadDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name = file.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final outPath = '${dir.path}\\$name.mp3';
    _emit(EngineEvent(id: id, type: 'start'));
    final proc = await Process.start('$_appDir\\ffmpeg.exe', [
      '-y',
      '-i',
      inputPath,
      '-vn',
      '-acodec',
      'libmp3lame',
      '-q:a',
      '0',
      outPath,
    ]);
    _procs[id] = proc;
    var lastPct = 0.0;
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        final m = RegExp(r'time=(\d+):(\d+):(\d+)').firstMatch(line);
        if (m != null) {
          final secs = int.parse(m.group(1)!) * 3600 +
              int.parse(m.group(2)!) * 60 +
              int.parse(m.group(3)!);
          // Estimación con duración desconocida: avance suave.
          final pct = (secs / 6).clamp(0, 99).toDouble();
          if (pct > lastPct) {
            lastPct = pct;
            _emit(EngineEvent(
                id: id, type: 'progress', progress: pct));
          }
        }
      },
    );
    final code = await proc.exitCode;
    _procs.remove(id);
    if (code == 0 && File(outPath).existsSync()) {
      _emit(EngineEvent(id: id, type: 'done', progress: 100, path: outPath));
    } else {
      _emit(EngineEvent(
          id: id, type: 'error', message: 'ffmpeg terminó con error ($code)'));
    }
  }
}
