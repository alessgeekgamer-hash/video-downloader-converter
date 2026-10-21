import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_item.dart';
import 'download_service.dart';
import 'ios_engine.dart';

/// Estado global de la aplicación: motor de descarga + lista de descargas.
class AppController extends ChangeNotifier {
  AppController._();
  static final AppController instance = AppController._();

  final DownloadService _engine = DownloadService.instance;

  String engineStatus = 'loading'; // loading | ready | error
  String engineVersion = '';
  String engineError = '';
  bool storageGranted = false;

  /// Carpeta personalizada por el usuario (null = predeterminada).
  String? downloadFolder;
  String? _defaultDir;

  final List<DownloadItem> items = [];
  StreamSubscription? _sub;
  SharedPreferences? _prefs;

  Future<void> start() async {
    try {
      _prefs = await SharedPreferences.getInstance().timeout(
          const Duration(seconds: 10));
      _loadHistory();
      downloadFolder = _prefs?.getString('downloadFolder');
    } catch (_) {
      // Sin preferencias la app sigue funcionando (solo sin historial).
    }
    _sub = _engine.events.listen(_onEvent, onError: (_) {});
    notifyListeners();
    await reinit();
  }

  Future<void> reinit() async {
    engineStatus = 'loading';
    notifyListeners();
    try {
      // Nunca bloquear más de 45 s: si el motor tarda, se puede reintentar.
      final res = await _engine.initEngine().timeout(const Duration(seconds: 45));
      if (res['ok'] == true) {
        engineStatus = 'ready';
        engineVersion = (res['version'] as String?) ?? '';
      } else {
        engineStatus = 'error';
        engineError = (res['error'] as String?) ?? 'Error desconocido';
      }
    } on TimeoutException {
      engineStatus = 'error';
      engineError =
          'El motor tardó demasiado en iniciar (posible primera ejecución). Toca Reintentar.';
    } catch (e) {
      engineStatus = 'error';
      engineError = e.toString();
    }
    notifyListeners();
  }

  /// Pide permiso de almacenamiento solo cuando se va a descargar.
  Future<void> _ensureStorageForAction() async {
    if (engineStatus != 'ready') return;
    try {
      storageGranted =
          await _engine.ensureStorage().timeout(const Duration(seconds: 25));
    } catch (_) {
      storageGranted = false;
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------

  Future<void> startDownload({
    required String url,
    required bool audioOnly,
    required int maxHeight,
  }) async {
    await _ensureStorageForAction();
    final id = 'dl-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final item = DownloadItem(
      id: id,
      url: url,
      title: _titleFromUrl(url),
      audioOnly: audioOnly,
    );
    items.insert(0, item);
    notifyListeners();
    try {
      await _engine.startDownload(
        id: id,
        url: url,
        audioOnly: audioOnly,
        maxHeight: maxHeight,
        folder: downloadFolder,
      );
    } catch (e) {
      item.status = DownloadStatus.error;
      item.message = e.toString();
      notifyListeners();
    }
  }

  /// Carpeta predeterminada del sistema (sin personalizar).
  Future<String> defaultDownloadDir() async {
    if (_defaultDir == null) {
      try {
        _defaultDir = (await _engine.downloadDir()).path;
      } catch (_) {
        _defaultDir = '';
      }
    }
    return _defaultDir!;
  }

  /// Abre el selector de carpetas y guarda la elegida.
  Future<bool> pickFolder() async {
    final path = await _engine.pickDirectory();
    if (path != null && path.isNotEmpty) {
      downloadFolder = path;
      await _prefs?.setString('downloadFolder', path);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Vuelve a la carpeta predeterminada.
  Future<void> resetDownloadFolder() async {
    downloadFolder = null;
    await _prefs?.remove('downloadFolder');
    notifyListeners();
  }

  /// Convierte un archivo local a MP3 (solo Windows usa ffmpeg directo;
  /// en Android se usa yt-dlp sobre el archivo local).
  Future<void> startConvert(String inputPath) async {
    await _ensureStorageForAction();
    final id = 'cv-${DateTime.now().millisecondsSinceEpoch}';
    final fileName = inputPath.split(Platform.pathSeparator).last;
    final item = DownloadItem(
      id: id,
      url: inputPath,
      title: fileName,
      audioOnly: true,
    );
    items.insert(0, item);
    notifyListeners();
    try {
      if (_engine is WindowsEngine) {
        await _engine.convertLocal(id, inputPath, downloadFolder);
      } else if (_engine is IosEngine) {
        await _engine.convertLocal(id, inputPath);
      } else {
        await _engine.startDownload(
          id: id,
          url: inputPath,
          audioOnly: true,
          maxHeight: -1,
          folder: downloadFolder,
        );
      }
    } catch (e) {
      item.status = DownloadStatus.error;
      item.message = e.toString();
      notifyListeners();
    }
  }

  Future<void> cancel(String id) => _engine.cancel(id);

  /// Ejecuta un runner personalizado creando la tarjeta de descarga
  /// (usado por iOS, que necesita contexto del navegador para extraer
  /// la URL del video).
  Future<void> runDownload({
    required String title,
    required bool audioOnly,
    required String sourceUrl,
    required Future<void> Function(String id) runner,
  }) async {
    final id =
        'wb-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final item = DownloadItem(
      id: id,
      url: sourceUrl,
      title: title,
      audioOnly: audioOnly,
    );
    items.insert(0, item);
    notifyListeners();
    try {
      await runner(id);
    } catch (e) {
      item.status = DownloadStatus.error;
      item.message = e.toString();
      notifyListeners();
    }
  }

  Future<String> updateEngine() async {
    final msg = await _engine.updateEngine();
    notifyListeners();
    return msg;
  }

  Future<void> openFile(String path) => _engine.openFile(path);

  Future<Directory> downloadDir() => _engine.downloadDir();

  void removeItem(String id) {
    items.removeWhere((i) => i.id == id);
    _saveHistory();
    notifyListeners();
  }

  void clearFinished() {
    items.removeWhere((i) => i.status != DownloadStatus.running);
    _saveHistory();
    notifyListeners();
  }

  // -------------------------------------------------------------------------

  void _onEvent(EngineEvent e) {
    final item = items.where((i) => i.id == e.id).firstOrNull;
    if (item == null) return;
    switch (e.type) {
      case 'progress':
        if (e.progress > item.progress || e.progress == 0) {
          item.progress = e.progress.clamp(0, 100);
        }
        // El motor envía las líneas de salida; usamos algunas para
        // obtener el título real y la ruta del archivo.
        final msg = e.message;
        if (msg != null) {
          final dest = RegExp(r'Destination: (.+)$').firstMatch(msg);
          final merged = RegExp(r'Merging formats into "(.+)"').firstMatch(msg);
          if (merged != null) {
            item.path = merged.group(1)!.trim();
          } else if (dest != null) {
            final p = dest.group(1)!.trim();
            item.path = p;
            final name = p.split(RegExp(r'[/\\]')).last;
            if (name.isNotEmpty && !name.contains('.f')) item.title = name;
          }
        }
        break;
      case 'done':
        item.status = DownloadStatus.done;
        item.progress = 100;
        if (e.path != null && e.path!.isNotEmpty) item.path = e.path;
        break;
      case 'error':
        item.status = DownloadStatus.error;
        item.message = e.message ?? 'Error desconocido';
        break;
    }
    _saveHistory();
    notifyListeners();
  }

  String _titleFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uri.host;
      return last.isEmpty ? uri.host : last;
    } catch (_) {
      return url;
    }
  }

  void _loadHistory() {
    final raw = _prefs?.getString('history');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      items.addAll(list
          .map((e) => DownloadItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((i) => i.status != DownloadStatus.running));
    } catch (_) {}
  }

  void _saveHistory() {
    final finished =
        items.where((i) => i.status != DownloadStatus.running).take(100);
    _prefs?.setString(
        'history', jsonEncode(finished.map((i) => i.toJson()).toList()));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
