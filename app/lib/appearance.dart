import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// No account or cloud settings; presentation preference stays on-device.
class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController._() : super(ThemeMode.light);
  static final instance = AppearanceController._();
  static const _key = 'taptether.appearance.theme.v1';
  final _storage = const FlutterSecureStorage();

  Future<void> load() async {
    try {
      final stored = await _storage.read(key: _key);
      value = stored == 'dark' ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {
      value = ThemeMode.light;
    }
  }

  Future<void> setDark(bool dark) async {
    await _storage.write(key: _key, value: dark ? 'dark' : 'light');
    value = dark ? ThemeMode.dark : ThemeMode.light;
  }
}

class TapTetherPalette {
  static const teal = Color(0xFF087F73);
  static const ink = Color(0xFF172B35);
  static const canvas = Color(0xFFF5F7F9);
  static const paleTeal = Color(0xFFDFF3ED);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: teal,
      brightness: Brightness.light,
      primary: teal,
      surface: Colors.white,
    );
    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white, foregroundColor: ink,
        surfaceTintColor: Colors.transparent, centerTitle: false,
        toolbarHeight: 54, titleTextStyle: TextStyle(color: ink,
          fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.35),
      ),
      cardTheme: CardThemeData(
        color: Colors.white, elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFDCE6E9)),
        ),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      )),
      segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      )),
      expansionTileTheme: const ExpansionTileThemeData(
        tilePadding: EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: EdgeInsets.symmetric(horizontal: 12),
        shape: Border(), collapsedShape: Border(),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      )),
    );
  }

  static ThemeData dark() => ThemeData(
    brightness: Brightness.dark, useMaterial3: true,
    colorSchemeSeed: const Color(0xFF57E6C2),
    scaffoldBackgroundColor: const Color(0xFF102326),
    appBarTheme: const AppBarTheme(centerTitle: false, toolbarHeight: 54),
    cardTheme: CardThemeData(elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    )),
  );
}
