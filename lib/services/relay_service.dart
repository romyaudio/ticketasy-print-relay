import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'printer_service.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

const String agentVersion = '1.0.1';

class RelayService extends ChangeNotifier {
  IO.Socket? _socket;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _lastError = '';
  String? _updateAvailable;
  String? _serverUrl;
  String? _token;
  bool _isShuttingDown = false;

  final PrinterService _printerService = PrinterService();
  final List<String> _logs = [];

  // === Public getters ===
  ConnectionStatus get status => _status;
  String get lastError => _lastError;
  String? get updateAvailable => _updateAvailable;
  List<String> get logs => List.unmodifiable(_logs);
  PrinterService get printerService => _printerService;

  /// Connect to the backend via Socket.IO /print namespace
  void connect({required String serverUrl, required String token}) {
    _serverUrl = serverUrl;
    _token = token;
    _isShuttingDown = false;
    _doConnect();
  }

  /// Activate with a setup code
  Future<Map<String, dynamic>?> activate({
    required String serverUrl,
    required String setupCode,
  }) async {
    _addLog('Activando con código $setupCode...');
    _status = ConnectionStatus.connecting;
    _serverUrl = serverUrl;
    notifyListeners();

    final completer = Completer<Map<String, dynamic>?>();

    try {
      _socket?.dispose();

      _socket = IO.io(
        '$serverUrl/print',
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .enableAutoConnect()
            .disableReconnection()
            .build(),
      );

      _socket!.onConnect((_) {
        _addLog('Conectado, enviando código de activación...');
        _socket!.emit('activate', {'setupCode': setupCode});
      });

      _socket!.on('activated', (data) {
        if (!completer.isCompleted) {
          _addLog('✅ Activación exitosa');
          _token = data['connectionToken'];
          _status = ConnectionStatus.connected;
          notifyListeners();
          _checkForUpdates();
          completer.complete({
            'connectionToken': data['connectionToken'] ?? '',
            'stationId': data['stationId'] ?? '',
            'companyId': data['companyId'] ?? '',
            'locationId': data['locationId'] ?? '',
          });
        }
      });

      _socket!.on('connected', (data) {
        if (!completer.isCompleted) {
          _addLog('✅ Registrado como estación ${data['stationId']}');
          _status = ConnectionStatus.connected;
          notifyListeners();
          _checkForUpdates();
          completer.complete({
            'connectionToken': _token ?? '',
            'stationId': data['stationId'] ?? '',
          });
        }
      });

      _socket!.on('error', (data) {
        final message = data is Map ? (data['message'] ?? 'Error desconocido') : data.toString();
        _lastError = message;
        _addLog('❌ Error: $_lastError');
        _status = ConnectionStatus.error;
        notifyListeners();
        if (!completer.isCompleted) completer.complete(null);
      });

      _socket!.onConnectError((error) {
        _lastError = error.toString();
        _addLog('❌ Error de conexión: $_lastError');
        _status = ConnectionStatus.error;
        notifyListeners();
        if (!completer.isCompleted) completer.complete(null);
      });

      _socket!.onDisconnect((_) {
        if (!completer.isCompleted) {
          _lastError = 'Desconectado durante activación';
          _status = ConnectionStatus.disconnected;
          notifyListeners();
          completer.complete(null);
        }
      });

      // Setup event listeners for print commands (in case activation leads to immediate registration)
      _setupPrintListeners();

      // Timeout
      Future.delayed(const Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          _lastError = 'Timeout esperando respuesta';
          _addLog('❌ Timeout');
          _status = ConnectionStatus.error;
          notifyListeners();
          completer.complete(null);
        }
      });

      return await completer.future;
    } catch (e) {
      _lastError = e.toString();
      _addLog('❌ Error de conexión: $_lastError');
      _status = ConnectionStatus.error;
      notifyListeners();
      return null;
    }
  }

  /// Disconnect
  void disconnect() {
    _isShuttingDown = true;
    _socket?.dispose();
    _socket = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  // === Private methods ===

  void _doConnect() {
    if (_serverUrl == null || _token == null) return;
    if (_isShuttingDown) return;

    _status = ConnectionStatus.connecting;
    _addLog('Conectando a servidor...');
    notifyListeners();

    try {
      // Always destroy previous socket completely
      _socket?.dispose();
      _socket = null;

      // Create fresh socket - DISABLE auto reconnection (we handle it ourselves)
      _socket = IO.io(
        '$_serverUrl/print',
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .setAuth({'token': _token!})
            .enableAutoConnect()
            .disableReconnection() // We handle reconnection manually
            .build(),
      );

      _socket!.onConnect((_) {
        _status = ConnectionStatus.connected;
        _addLog('✅ Conectado');
        notifyListeners();
      });

      _socket!.on('connected', (data) {
        _status = ConnectionStatus.connected;
        _addLog('✅ Registrado como estación ${data['stationId']}');
        _checkForUpdates();
        notifyListeners();
      });

      _socket!.onDisconnect((reason) {
        if (_isShuttingDown) return;
        _addLog('Desconectado ($reason)');
        _status = ConnectionStatus.disconnected;
        notifyListeners();
        // Always recreate connection after any disconnect
        _scheduleReconnect();
      });

      _socket!.onConnectError((error) {
        if (_isShuttingDown) return;
        _lastError = error.toString();
        _addLog('Error: $_lastError');
        _status = ConnectionStatus.error;
        notifyListeners();
        // Retry on connection error
        _scheduleReconnect();
      });

      _socket!.on('error', (data) {
        final message = data is Map ? (data['message'] ?? 'Error') : data.toString();
        _lastError = message;
        _addLog('Error: $_lastError');
      });

      _setupPrintListeners();
    } catch (e) {
      _lastError = e.toString();
      _addLog('Error: $_lastError');
      _status = ConnectionStatus.error;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isShuttingDown) return;
    Future.delayed(const Duration(seconds: 3), () {
      if (!_isShuttingDown && _status != ConnectionStatus.connected) {
        _doConnect();
      }
    });
  }

  void _setupPrintListeners() {
    if (_socket == null) return;

    _socket!.on('print:receipt', (data) {
      _addLog('🖨️ Recibo recibido - imprimiendo...');
      _handlePrint(
        Map<String, dynamic>.from(data['data'] ?? {}),
        data['format'] is Map ? Map<String, dynamic>.from(data['format']) : {'type': data['format'] ?? 'escpos'},
      );
    });

    _socket!.on('print:test', (data) {
      _addLog('🖨️ Prueba de impresión recibida');
      _handleTestPrint(Map<String, dynamic>.from(data['data'] ?? {}));
    });

    _socket!.on('open:drawer', (_) {
      _addLog('💰 Abriendo cajón');
      _handleOpenDrawer();
    });

    _socket!.on('heartbeat_ack', (_) {
      // Socket.IO handles ping/pong internally, this is just for app-level ack
    });
  }

  void _handlePrint(Map<String, dynamic> receiptData, Map<String, dynamic> format) async {
    try {
      await _printerService.printReceipt(receiptData, format);
      _socket?.emit('print:completed', {'status': 'ok'});
      _addLog('✅ Recibo impreso');
      notifyListeners();
    } catch (e) {
      _socket?.emit('print:error', {'error': e.toString()});
      _addLog('❌ Error imprimiendo: $e');
      notifyListeners();
    }
  }

  void _handleTestPrint(Map<String, dynamic> data) async {
    try {
      await _printerService.printTest(data);
      _socket?.emit('print:completed', {'status': 'ok'});
      _addLog('✅ Prueba impresa');
      notifyListeners();
    } catch (e) {
      _socket?.emit('print:error', {'error': e.toString()});
      _addLog('❌ Error en prueba: $e');
      notifyListeners();
    }
  }

  void _handleOpenDrawer() async {
    try {
      await _printerService.openDrawer();
      _socket?.emit('print:completed', {'status': 'ok'});
      _addLog('✅ Cajón abierto');
      notifyListeners();
    } catch (e) {
      _socket?.emit('print:error', {'error': e.toString()});
      _addLog('❌ Error abriendo cajón: $e');
      notifyListeners();
    }
  }

  /// Check GitHub Releases for a newer version
  Future<void> _checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/romyaudio/ticketasy-print-relay/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final latestTag = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
        if (latestTag.isNotEmpty && latestTag != agentVersion) {
          _updateAvailable = latestTag;
          _addLog('⬆️ Actualización disponible: v$latestTag');
          notifyListeners();
        }
      }
    } catch (_) {
      // Silent fail - not critical
    }
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    _logs.add('[$timestamp] $message');
    if (_logs.length > 50) _logs.removeAt(0);
  }
}
