import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/app_controller.dart';
import 'tabs/convert_tab.dart';
import 'tabs/extract_tab.dart';
import 'tabs/home_tab.dart';
import 'tabs/web_tab.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Barra de estado y navegación de Android ocultas (modo inmersivo).
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // Windows: si se lanza con una URL, abrir directo en la pestaña
  // Universal y analizarla automáticamente.
  String? launchUrl;
  if (Platform.isWindows && args.isNotEmpty && args.first.startsWith('http')) {
    launchUrl = args.first;
  }
  runApp(VdcApp(launchUrl: launchUrl));
  // El motor (yt-dlp/FFmpeg/permisos) se inicializa DESPUÉS de mostrar la
  // interfaz, nunca antes: si tarda, la app muestra "Preparando motor...".
  Future.delayed(const Duration(milliseconds: 300),
      () => AppController.instance.start());
}

class VdcApp extends StatelessWidget {
  const VdcApp({super.key, this.launchUrl});

  final String? launchUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Downloader & Converter',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: AppShell(launchUrl: launchUrl),
    );
  }

  ThemeData _theme(Brightness brightness) {
    // Violeta vivo como base, rosa fucsia como acento llamativo.
    const seed = Color(0xFF7C3AED);
    const accent = Color(0xFFFF2D78);
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
        .copyWith(secondary: accent);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: .35),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: accent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
              color: selected ? Colors.white : scheme.onSurfaceVariant);
        }),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.launchUrl});

  /// URL recibida al lanzar la app (Windows): abre la pestaña Universal.
  final String? launchUrl;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.launchUrl != null ? 4 : 0;
  }

  void _goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    // La pestaña Universal (descargar de cualquier sitio por URL) es
    // para Windows (yt-dlp) y iOS (descarga directa/HLS por HTML).
    final showUniversal = Platform.isWindows || Platform.isIOS;

    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home_rounded),
        label: 'Inicio',
      ),
      const NavigationDestination(
        icon: Icon(Icons.smart_display_outlined),
        selectedIcon: Icon(Icons.smart_display_rounded),
        label: 'YouTube',
      ),
      const NavigationDestination(
        icon: Icon(Icons.music_note_outlined),
        selectedIcon: Icon(Icons.music_note_rounded),
        label: 'TikTok',
      ),
      const NavigationDestination(
        icon: Icon(Icons.sync_alt_outlined),
        selectedIcon: Icon(Icons.sync_alt_rounded),
        label: 'Convertir',
      ),
      if (showUniversal)
        const NavigationDestination(
          icon: Icon(Icons.travel_explore_outlined),
          selectedIcon: Icon(Icons.travel_explore_rounded),
          label: 'Universal',
        ),
    ];

    final tabs = <Widget>[
      HomeTab(),
      WebTab(
        title: 'YouTube',
        icon: Icons.smart_display_rounded,
        initialUrl: 'https://m.youtube.com/',
        onOpenDownloads: () => _goTo(0),
        active: _index == 1,
      ),
      WebTab(
        title: 'TikTok',
        icon: Icons.music_note_rounded,
        initialUrl: 'https://www.tiktok.com/',
        onOpenDownloads: () => _goTo(0),
        active: _index == 2,
      ),
      ConvertTab(),
      if (showUniversal)
        ExtractTab(
          onOpenDownloads: () => _goTo(0),
          initialUrl: widget.launchUrl,
        ),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: tabs,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: destinations,
      ),
    );
  }
}
