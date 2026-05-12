import 'dart:io';
import 'dart:async';

class DiscoveredPrinter {
  final String name;
  final String type; // 'USB' or 'NETWORK'
  final String? address; // IP:port for network printers
  final bool isDefault;

  DiscoveredPrinter({
    required this.name,
    required this.type,
    this.address,
    this.isDefault = false,
  });
}

class PrinterDiscovery {
  /// List all printers installed in the OS (USB/system printers)
  static Future<List<DiscoveredPrinter>> listSystemPrinters() async {
    final printers = <DiscoveredPrinter>[];

    try {
      if (Platform.isWindows) {
        final result = await Process.run(
          'wmic',
          ['printer', 'get', 'Name,Default', '/format:csv'],
          runInShell: true,
        );
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).split('\n');
          for (final line in lines) {
            final parts = line.trim().split(',');
            if (parts.length >= 3 && parts[1].isNotEmpty && parts[1] != 'Default') {
              final isDefault = parts[1].toUpperCase() == 'TRUE';
              final name = parts[2].trim();
              if (name.isNotEmpty) {
                printers.add(DiscoveredPrinter(name: name, type: 'USB', isDefault: isDefault));
              }
            }
          }
        }
      } else if (Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('lpstat', ['-p'], runInShell: true);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).split('\n');
          for (final line in lines) {
            if (line.startsWith('printer ')) {
              final name = line.split(' ')[1];
              printers.add(DiscoveredPrinter(name: name, type: 'USB'));
            }
          }
        }
        final defaultResult = await Process.run('lpstat', ['-d'], runInShell: true);
        if (defaultResult.exitCode == 0) {
          final defaultName = (defaultResult.stdout as String).split(':').last.trim();
          for (int i = 0; i < printers.length; i++) {
            if (printers[i].name == defaultName) {
              printers[i] = DiscoveredPrinter(name: printers[i].name, type: 'USB', isDefault: true);
            }
          }
        }
      }
    } catch (e) {
      // Silently fail
    }

    return printers;
  }

  /// Scan local network for thermal printers (port 9100)
  static Future<List<DiscoveredPrinter>> scanNetworkPrinters({
    Function(int scanned, int total)? onProgress,
  }) async {
    final printers = <DiscoveredPrinter>[];

    try {
      // Get local IP to determine network range
      final localIp = await _getLocalIp();
      if (localIp == null) return printers;

      // Extract subnet (e.g., 192.168.1)
      final parts = localIp.split('.');
      if (parts.length != 4) return printers;
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

      // Scan all IPs in subnet on port 9100 (thermal printer standard port)
      const port = 9100;
      const timeout = Duration(milliseconds: 300);
      int scanned = 0;

      // Scan in batches of 20 for speed
      for (int batch = 1; batch <= 254; batch += 20) {
        final futures = <Future>[];
        for (int i = batch; i < batch + 20 && i <= 254; i++) {
          final ip = '$subnet.$i';
          futures.add(_checkPort(ip, port, timeout).then((open) {
            scanned++;
            onProgress?.call(scanned, 254);
            if (open) {
              printers.add(DiscoveredPrinter(
                name: 'Impresora en $ip',
                type: 'NETWORK',
                address: '$ip:$port',
              ));
            }
          }));
        }
        await Future.wait(futures);
      }
    } catch (e) {
      // Silently fail
    }

    return printers;
  }

  /// Check if a port is open on a given IP
  static Future<bool> _checkPort(String ip, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      await socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get the local IP address
  static Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface_ in interfaces) {
        for (final addr in interface_.addresses) {
          if (addr.address.startsWith('192.168.') ||
              addr.address.startsWith('10.') ||
              addr.address.startsWith('172.')) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      // Silently fail
    }
    return null;
  }
}
