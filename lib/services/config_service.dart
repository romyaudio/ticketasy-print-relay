import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  late SharedPreferences _prefs;

  // Default server URL (set via --dart-define=ENV=dev or ENV=prod at build time)
  static const String _env = String.fromEnvironment('ENV', defaultValue: 'dev');
  static const String _defaultServerUrl = _env == 'prod'
      ? 'wss://ticketventas.com/ws/print'
      : 'ws://localhost:3010/ws/print';

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // === Getters ===

  bool get isActivated => connectionToken != null && connectionToken!.isNotEmpty;

  String? get connectionToken => _prefs.getString('connectionToken');
  String? get stationId => _prefs.getString('stationId');
  String? get companyId => _prefs.getString('companyId');
  String? get locationId => _prefs.getString('locationId');
  String get serverUrl => _prefs.getString('serverUrl') ?? _defaultServerUrl;

  String? get printerType => _prefs.getString('printerType');
  String? get printerAddress => _prefs.getString('printerAddress');
  String? get printerName => _prefs.getString('printerName');

  // === Setters ===

  Future<void> saveActivation({
    required String connectionToken,
    required String stationId,
    required String companyId,
    required String locationId,
  }) async {
    await _prefs.setString('connectionToken', connectionToken);
    await _prefs.setString('stationId', stationId);
    await _prefs.setString('companyId', companyId);
    await _prefs.setString('locationId', locationId);
  }

  Future<void> saveServerUrl(String url) async {
    await _prefs.setString('serverUrl', url);
  }

  Future<void> savePrinterConfig({
    required String type,
    String? address,
    String? name,
  }) async {
    await _prefs.setString('printerType', type);
    if (address != null) await _prefs.setString('printerAddress', address);
    if (name != null) await _prefs.setString('printerName', name);
  }

  Future<void> clearAll() async {
    await _prefs.clear();
  }
}
