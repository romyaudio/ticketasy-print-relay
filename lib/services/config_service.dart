import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // === Getters ===

  bool get isConfigured => printerType != null && printerType!.isNotEmpty;

  String? get printerType => _prefs.getString('printerType');
  String? get printerAddress => _prefs.getString('printerAddress');
  String? get printerName => _prefs.getString('printerName');

  // === Setters ===

  Future<void> savePrinterConfig({
    required String type,
    String? address,
    String? name,
  }) async {
    await _prefs.setString('printerType', type);
    if (address != null) {
      await _prefs.setString('printerAddress', address);
    } else {
      await _prefs.remove('printerAddress');
    }
    if (name != null) {
      await _prefs.setString('printerName', name);
    } else {
      await _prefs.remove('printerName');
    }
  }

  Future<void> clearAll() async {
    await _prefs.clear();
  }
}
