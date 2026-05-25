import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'printer_service.dart';

enum ServerStatus { stopped, running, error }

const String agentVersion = '1.0.5';
const int defaultPort = 12345;

/// Allowed origins that can connect to the local print server
const List<String> allowedOrigins = [
  'https://ticketventas.com',
  'http://localhost:3000',
  'http://localhost:3001',
];

class LocalPrintServer extends ChangeNotifier {
  HttpServer? _server;
  ServerStatus _status = ServerStatus.stopped;
  String _lastError = '';
  String? _updateAvailable;
  int _port = defaultPort;
  int _activeConnections = 0;

  final PrinterService _printerService = PrinterService();
  final List<String> _logs = [];
  final Set<WebSocket> _clients = {};

  // === Public getters ===
  ServerStatus get status => _status;
  String get lastError => _lastError;
  String? get updateAvailable => _updateAvailable;
  int get port => _port;
  int get activeConnections => _activeConnections;
  List<String> get logs => List.unmodifiable(_logs);
  PrinterService get printerService => _printerService;
  bool get isRunning => _status == ServerStatus.running;

  /// Start the local WebSocket server
  Future<void> start() async {
    if (_status == ServerStatus.running) return;

    try {
      // Try the default port, then fallback to next ones
      for (int attempt = 0; attempt < 5; attempt++) {
        try {
          _server = await HttpServer.bind(
            InternetAddress.loopbackIPv4, // 127.0.0.1 only
            _port + attempt,
          );
          _port = defaultPort + attempt;
          break;
        } on SocketException {
          if (attempt == 4) rethrow;
        }
      }

      _status = ServerStatus.running;
      _addLog('✅ Servidor local iniciado en puerto $_port');
      notifyListeners();

      _checkForUpdates();

      // Handle incoming connections
      _server!.listen(
        _handleRequest,
        onError: (error) {
          _addLog('Error en servidor: $error');
        },
      );
    } catch (e) {
      _lastError = e.toString();
      _status = ServerStatus.error;
      _addLog('❌ Error iniciando servidor: $_lastError');
      notifyListeners();
    }
  }

  /// Stop the server
  Future<void> stop() async {
    for (final client in _clients.toList()) {
      try {
        await client.close(1001, 'Server shutting down');
      } catch (_) {}
    }
    _clients.clear();
    _activeConnections = 0;

    await _server?.close(force: true);
    _server = null;
    _status = ServerStatus.stopped;
    _addLog('Servidor detenido');
    notifyListeners();
  }

  /// Handle incoming HTTP requests
  void _handleRequest(HttpRequest request) async {
    // CORS preflight
    if (request.method == 'OPTIONS') {
      _setCorsHeaders(request.response, request);
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }

    // Health check endpoint
    if (request.uri.path == '/health' && request.method == 'GET') {
      _setCorsHeaders(request.response, request);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'status': 'ok',
          'version': agentVersion,
          'printer': _printerService.isConfigured
              ? {'configured': true}
              : {'configured': false},
        }));
      await request.response.close();
      return;
    }

    // Printer info endpoint
    if (request.uri.path == '/printer' && request.method == 'GET') {
      _setCorsHeaders(request.response, request);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'configured': _printerService.isConfigured,
        }));
      await request.response.close();
      return;
    }

    // WebSocket upgrade
    if (request.uri.path == '/ws') {
      // Validate origin
      final origin = request.headers.value('origin') ?? '';
      if (!_isOriginAllowed(origin)) {
        _addLog('⚠️ Origen rechazado: $origin');
        request.response
          ..statusCode = 403
          ..write('Forbidden');
        await request.response.close();
        return;
      }

      try {
        final ws = await WebSocketTransformer.upgrade(request);
        _handleWebSocket(ws, origin);
      } catch (e) {
        _addLog('Error en WebSocket upgrade: $e');
      }
      return;
    }

    // 404 for everything else
    request.response
      ..statusCode = 404
      ..write('Not found');
    await request.response.close();
  }

  /// Handle a WebSocket connection
  void _handleWebSocket(WebSocket ws, String origin) {
    _clients.add(ws);
    _activeConnections = _clients.length;
    _addLog('🔌 Cliente conectado ($origin) [${_clients.length} activos]');
    notifyListeners();

    ws.listen(
      (data) {
        _handleMessage(ws, data);
      },
      onDone: () {
        _clients.remove(ws);
        _activeConnections = _clients.length;
        _addLog('🔌 Cliente desconectado [${_clients.length} activos]');
        notifyListeners();
      },
      onError: (error) {
        _clients.remove(ws);
        _activeConnections = _clients.length;
        _addLog('Error WebSocket: $error');
        notifyListeners();
      },
    );

    // Send initial status
    _sendJson(ws, {
      'type': 'status',
      'data': {
        'version': agentVersion,
        'printerConfigured': _printerService.isConfigured,
      },
    });
  }

  /// Handle incoming WebSocket message
  void _handleMessage(WebSocket ws, dynamic rawData) async {
    try {
      final message = jsonDecode(rawData as String) as Map<String, dynamic>;
      final type = message['type'] as String?;

      switch (type) {
        case 'print:receipt':
          await _handlePrintReceipt(ws, message);
          break;
        case 'print:test':
          await _handleTestPrint(ws, message);
          break;
        case 'open:drawer':
          await _handleOpenDrawer(ws);
          break;
        case 'ping':
          _sendJson(ws, {'type': 'pong'});
          break;
        default:
          _sendJson(ws, {'type': 'error', 'message': 'Unknown message type: $type'});
      }
    } catch (e) {
      _addLog('Error procesando mensaje: $e');
      _sendJson(ws, {'type': 'error', 'message': e.toString()});
    }
  }

  /// Handle print receipt command
  Future<void> _handlePrintReceipt(WebSocket ws, Map<String, dynamic> message) async {
    _addLog('🖨️ Recibo recibido - imprimiendo...');
    try {
      final data = Map<String, dynamic>.from(message['data'] ?? {});
      final format = message['format'] is Map
          ? Map<String, dynamic>.from(message['format'])
          : <String, dynamic>{};
      await _printerService.printReceipt(data, format);
      _sendJson(ws, {'type': 'print:completed', 'status': 'ok'});
      _addLog('✅ Recibo impreso');
      notifyListeners();
    } catch (e) {
      _sendJson(ws, {'type': 'print:error', 'error': e.toString()});
      _addLog('❌ Error imprimiendo: $e');
      notifyListeners();
    }
  }

  /// Handle test print command
  Future<void> _handleTestPrint(WebSocket ws, Map<String, dynamic> message) async {
    _addLog('🖨️ Prueba de impresión');
    try {
      final data = Map<String, dynamic>.from(message['data'] ?? {});
      await _printerService.printTest(data);
      _sendJson(ws, {'type': 'print:completed', 'status': 'ok'});
      _addLog('✅ Prueba impresa');
      notifyListeners();
    } catch (e) {
      _sendJson(ws, {'type': 'print:error', 'error': e.toString()});
      _addLog('❌ Error en prueba: $e');
      notifyListeners();
    }
  }

  /// Handle open drawer command
  Future<void> _handleOpenDrawer(WebSocket ws) async {
    _addLog('💰 Abriendo cajón');
    try {
      await _printerService.openDrawer();
      _sendJson(ws, {'type': 'print:completed', 'status': 'ok'});
      _addLog('✅ Cajón abierto');
      notifyListeners();
    } catch (e) {
      _sendJson(ws, {'type': 'print:error', 'error': e.toString()});
      _addLog('❌ Error abriendo cajón: $e');
      notifyListeners();
    }
  }

  /// Send JSON message to a WebSocket client
  void _sendJson(WebSocket ws, Map<String, dynamic> data) {
    try {
      ws.add(jsonEncode(data));
    } catch (_) {}
  }

  /// Set CORS headers for HTTP responses
  void _setCorsHeaders(HttpResponse response, HttpRequest request) {
    final origin = request.headers.value('origin') ?? '';
    if (_isOriginAllowed(origin)) {
      response.headers.set('Access-Control-Allow-Origin', origin);
    }
    response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }

  /// Check if an origin is allowed
  bool _isOriginAllowed(String origin) {
    if (origin.isEmpty) return true; // Allow no-origin (e.g. curl, Postman)
    return allowedOrigins.any((allowed) => origin.startsWith(allowed));
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
    } catch (_) {}
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    _logs.add('[$timestamp] $message');
    if (_logs.length > 50) _logs.removeAt(0);
  }
}
