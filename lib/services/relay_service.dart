import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'printer_service.dart';

enum ConnectionStatus { disconnected, connecting, connected, error }

const String agentVersion = '1.0.0';

class RelayService extends ChangeNotifier {
  WebSocketChannel? _channel;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _lastError = '';
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  String? _updateAvailable; // null = no update, otherwise = new version
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

  /// Connect to the backend WebSocket
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
      final uri = Uri.parse(serverUrl);
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      // Send activation message
      _channel!.sink.add(jsonEncode({
        'type': 'activate',
        'setupCode': setupCode,
      }));

      // Listen for all messages
      _channel!.stream.listen(
        (data) {
          try {
            final message = jsonDecode(data as String);

            if (!completer.isCompleted && (message['type'] == 'activated' || message['type'] == 'connected')) {
              _addLog('✅ Activación exitosa');
              _status = ConnectionStatus.connected;
              _reconnectAttempts = 0;
              if (message['connectionToken'] != null) {
                _token = message['connectionToken'];
              }
              _startHeartbeat();
              notifyListeners();
              if (!completer.isCompleted) {
                completer.complete({
                  'connectionToken': message['connectionToken'] ?? _token ?? '',
                  'stationId': message['stationId'] ?? '',
                  'companyId': message['companyId'] ?? '',
                  'locationId': message['locationId'] ?? '',
                });
              }
            } else if (!completer.isCompleted && message['type'] == 'error') {
              _lastError = message['message'] ?? 'Error desconocido';
              _addLog('❌ Error: $_lastError');
              _status = ConnectionStatus.error;
              notifyListeners();
              completer.complete(null);
            } else {
              // Handle normal messages after activation
              _onMessage(data);
            }
          } catch (e) {
            if (!completer.isCompleted) {
              _lastError = e.toString();
              completer.complete(null);
            }
          }
        },
        onError: (error) {
          _addLog('Error: $error');
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          notifyListeners();
          if (!completer.isCompleted) completer.complete(null);
          _scheduleReconnect();
        },
        onDone: () {
          _heartbeatTimer?.cancel();
          if (!_isShuttingDown) {
            _addLog('Desconectado. Reconectando...');
            _status = ConnectionStatus.disconnected;
            notifyListeners();
            _scheduleReconnect();
          }
        },
      );

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
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _status = ConnectionStatus.disconnected;
    notifyListeners();
  }

  // === Private methods ===

  void _doConnect() {
    if (_serverUrl == null || _token == null) return;

    _status = ConnectionStatus.connecting;
    _addLog('Conectando a servidor...');
    notifyListeners();

    try {
      final uri = Uri.parse('$_serverUrl?token=$_token');
      _channel = WebSocketChannel.connect(uri);

      _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          _addLog('Error: $error');
          _status = ConnectionStatus.error;
          _lastError = error.toString();
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          _heartbeatTimer?.cancel();
          if (!_isShuttingDown) {
            _addLog('Desconectado. Reconectando...');
            _status = ConnectionStatus.disconnected;
            notifyListeners();
            _scheduleReconnect();
          }
        },
      );

      // Wait a moment then assume connected (WebSocket doesn't have onOpen in this lib)
      Future.delayed(const Duration(seconds: 1), () {
        if (_status == ConnectionStatus.connecting) {
          _status = ConnectionStatus.connected;
          _reconnectAttempts = 0;
          _addLog('✅ Conectado');
          _startHeartbeat();
          notifyListeners();
        }
      });
    } catch (e) {
      _lastError = e.toString();
      _addLog('Error de conexión: $_lastError');
      _status = ConnectionStatus.error;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    try {
      final message = jsonDecode(data as String);

      switch (message['type']) {
        case 'connected':
          _status = ConnectionStatus.connected;
          _reconnectAttempts = 0;
          _addLog('✅ Registrado como estación ${message['stationId']}');
          _startHeartbeat();
          _checkForUpdates();
          notifyListeners();
          break;

        case 'heartbeat_ack':
          break;

        case 'print:receipt':
          _addLog('🖨️ Recibo recibido - imprimiendo...');
          _handlePrint(message['data'], message['format']);
          break;

        case 'print:test':
          _addLog('🖨️ Prueba de impresión recibida');
          _handleTestPrint(message['data']);
          break;

        case 'open:drawer':
          _addLog('💰 Abriendo cajón');
          _handleOpenDrawer();
          break;

        default:
          _addLog('Mensaje: ${message['type']}');
      }
    } catch (e) {
      _addLog('Error procesando mensaje: $e');
    }
  }

  void _handlePrint(Map<String, dynamic> receiptData, Map<String, dynamic> format) async {
    try {
      await _printerService.printReceipt(receiptData, format);
      _sendMessage({'type': 'print:completed'});
      _addLog('✅ Recibo impreso');
      notifyListeners();
    } catch (e) {
      _sendMessage({'type': 'print:error', 'error': e.toString()});
      _addLog('❌ Error imprimiendo: $e');
      notifyListeners();
    }
  }

  void _handleTestPrint(Map<String, dynamic> data) async {
    try {
      await _printerService.printTest(data);
      _sendMessage({'type': 'print:completed'});
      _addLog('✅ Prueba impresa');
      notifyListeners();
    } catch (e) {
      _sendMessage({'type': 'print:error', 'error': e.toString()});
      _addLog('❌ Error en prueba: $e');
      notifyListeners();
    }
  }

  void _handleOpenDrawer() async {
    try {
      await _printerService.openDrawer();
      _sendMessage({'type': 'print:completed'});
      _addLog('✅ Cajón abierto');
      notifyListeners();
    } catch (e) {
      _sendMessage({'type': 'print:error', 'error': e.toString()});
      _addLog('❌ Error abriendo cajón: $e');
      notifyListeners();
    }
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendMessage({'type': 'heartbeat'});
    });
  }

  void _scheduleReconnect() {
    if (_isShuttingDown) return;
    _reconnectAttempts++;
    final delay = Duration(
      seconds: (_reconnectAttempts * 2).clamp(1, 30),
    );
    _addLog('Reconectando en ${delay.inSeconds}s...');
    _reconnectTimer = Timer(delay, _doConnect);
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
