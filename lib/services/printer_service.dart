import 'dart:io';
import 'dart:typed_data';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;

class PrinterService {
  String? _printerType; // 'NETWORK' or 'USB'
  String? _printerAddress; // IP:port for network
  String? _printerName; // OS printer name for USB

  void configure({
    required String type,
    String? address,
    String? name,
  }) {
    _printerType = type;
    _printerAddress = address;
    _printerName = name;
  }

  bool get isConfigured => _printerType != null;

  /// Print a receipt
  Future<void> printReceipt(Map<String, dynamic> data, Map<String, dynamic> format) async {
    final bytes = await _buildReceiptBytes(data, format);
    await _sendToPrinter(bytes);
  }

  /// Print a test page
  Future<void> printTest(Map<String, dynamic> data) async {
    final bytes = await _buildTestBytes(data);
    await _sendToPrinter(bytes);
  }

  /// Open cash drawer only (no print)
  Future<void> openDrawer() async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];
    bytes += generator.drawer();
    await _sendToPrinter(bytes);
  }

  /// Build ESC/POS bytes for a receipt
  Future<List<int>> _buildReceiptBytes(Map<String, dynamic> data, Map<String, dynamic> format) async {
    final paperSize = (format['paperWidth'] ?? '80mm') == '58mm' ? PaperSize.mm58 : PaperSize.mm80;
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    bytes += generator.setStyles(const PosStyles(align: PosAlign.center));

    // Print logo if available (cached locally)
    if (data['companyLogo'] != null && (data['companyLogo'] as String).isNotEmpty) {
      try {
        final logoFile = await _getCachedLogo(data['companyLogo'] as String);
        if (logoFile != null) {
          final originalImage = img.decodeImage(await logoFile.readAsBytes());
          if (originalImage != null) {
            final resized = img.copyResize(originalImage, 
              width: originalImage.width > originalImage.height ? 300 : 150);
            // Convert to monochrome with Floyd-Steinberg dithering
            // First: increase brightness, then convert to grayscale, then dither
            final grayscale = img.grayscale(resized);
            // Increase brightness
            for (int y = 0; y < grayscale.height; y++) {
              for (int x = 0; x < grayscale.width; x++) {
                final pixel = grayscale.getPixel(x, y);
                final r = img.getRed(pixel);
                // Boost brightness by 60%
                final bright = (r * 1.6).round().clamp(0, 255);
                grayscale.setPixel(x, y, img.getColor(bright, bright, bright));
              }
            }
            // Floyd-Steinberg dithering for monochrome output
            for (int y = 0; y < grayscale.height; y++) {
              for (int x = 0; x < grayscale.width; x++) {
                final oldPixel = img.getRed(grayscale.getPixel(x, y));
                final newPixel = oldPixel < 128 ? 0 : 255;
                final error = oldPixel - newPixel;
                grayscale.setPixel(x, y, img.getColor(newPixel, newPixel, newPixel));
                // Distribute error to neighbors
                if (x + 1 < grayscale.width) {
                  final n = img.getRed(grayscale.getPixel(x + 1, y));
                  grayscale.setPixel(x + 1, y, img.getColor((n + error * 7 / 16).round().clamp(0, 255), (n + error * 7 / 16).round().clamp(0, 255), (n + error * 7 / 16).round().clamp(0, 255)));
                }
                if (x - 1 >= 0 && y + 1 < grayscale.height) {
                  final n = img.getRed(grayscale.getPixel(x - 1, y + 1));
                  grayscale.setPixel(x - 1, y + 1, img.getColor((n + error * 3 / 16).round().clamp(0, 255), (n + error * 3 / 16).round().clamp(0, 255), (n + error * 3 / 16).round().clamp(0, 255)));
                }
                if (y + 1 < grayscale.height) {
                  final n = img.getRed(grayscale.getPixel(x, y + 1));
                  grayscale.setPixel(x, y + 1, img.getColor((n + error * 5 / 16).round().clamp(0, 255), (n + error * 5 / 16).round().clamp(0, 255), (n + error * 5 / 16).round().clamp(0, 255)));
                }
                if (x + 1 < grayscale.width && y + 1 < grayscale.height) {
                  final n = img.getRed(grayscale.getPixel(x + 1, y + 1));
                  grayscale.setPixel(x + 1, y + 1, img.getColor((n + error * 1 / 16).round().clamp(0, 255), (n + error * 1 / 16).round().clamp(0, 255), (n + error * 1 / 16).round().clamp(0, 255)));
                }
              }
            }
            bytes += generator.image(grayscale);
            bytes += generator.feed(1);
          }
        }
      } catch (_) {
        // Skip logo if not available
      }
    }

    // Company name - force double size with raw ESC/POS commands
    bytes += [0x1B, 0x61, 0x01]; // Center align
    bytes += [0x1B, 0x45, 0x01]; // Bold ON
    bytes += [0x1D, 0x21, 0x01]; // Double height only (normal width)
    bytes += generator.textEncoded(Uint8List.fromList((data['companyName'] ?? 'RECIBO').codeUnits));
    bytes += [0x0A]; // Line feed
    bytes += [0x1D, 0x21, 0x00]; // Normal size
    bytes += [0x1B, 0x45, 0x00]; // Bold OFF
    bytes += generator.setStyles(const PosStyles(align: PosAlign.center, bold: false, height: PosTextSize.size1, width: PosTextSize.size1));

    if (format['showAddress'] == true && data['companyAddress'] != null) {
      bytes += generator.text(data['companyAddress']);
    }
    if (format['showPhone'] == true && data['companyPhone'] != null) {
      bytes += generator.text('Tel: ${data['companyPhone']}');
    }
    if (data['locationName'] != null && (data['locationName'] as String).isNotEmpty) {
      bytes += generator.text(data['locationName']);
    }

    bytes += generator.hr(ch: '=');
    bytes += generator.setStyles(const PosStyles(align: PosAlign.left));

    // Get labels from backend (with fallbacks)
    final labels = data['labels'] as Map<String, dynamic>? ?? {};
    final lDate = labels['date'] ?? 'Fecha';
    final lTime = labels['time'] ?? 'Hora';
    final lServedBy = labels['servedBy'] ?? 'Atendido por';
    final lOrder = labels['order'] ?? 'Orden';
    final lSubtotal = labels['subtotal'] ?? 'Subtotal';
    final lTaxes = labels['taxes'] ?? 'Impuestos';
    final lDiscount = labels['discount'] ?? 'Descuento';
    final lTotal = labels['total'] ?? 'TOTAL';
    final lMethod = labels['method'] ?? 'Metodo';
    final lPaid = labels['paid'] ?? 'Pagado';
    final lChange = labels['change'] ?? 'Cambio';
    final paymentMethods = {
      'CASH': labels['cash'] ?? 'Efectivo',
      'CARD': labels['card'] ?? 'Tarjeta',
      'TRANSFER': labels['transfer'] ?? 'Transferencia',
      'CHECK': labels['check'] ?? 'Cheque',
      'OTHER': labels['other'] ?? 'Otro',
    };

    // Date & employee (use local timezone of the machine)
    final formattedDate = data['formattedDate'] as String?;
    final formattedTime = data['formattedTime'] as String?;
    if (formattedDate != null && formattedTime != null) {
      bytes += generator.text('$lDate: $formattedDate  $lTime: $formattedTime');
    } else {
      final createdAt = (DateTime.tryParse(data['createdAt'] ?? '') ?? DateTime.now()).toLocal();
      final hour = createdAt.hour > 12 ? createdAt.hour - 12 : (createdAt.hour == 0 ? 12 : createdAt.hour);
      final ampm = createdAt.hour >= 12 ? 'PM' : 'AM';
      bytes += generator.text('$lDate: ${createdAt.day.toString().padLeft(2, '0')}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.year}  $lTime: $hour:${createdAt.minute.toString().padLeft(2, '0')} $ampm');
    }

    if (format['showEmployee'] == true && data['employeeName'] != null) {
      bytes += generator.text('$lServedBy: ${data['employeeName']}');
    }

    if (format['showOrderNumber'] == true) {
      final orderId = data['orderId'] ?? '';
      bytes += generator.text('$lOrder: #${orderId.length > 8 ? orderId.substring(orderId.length - 8) : orderId}');
    }

    bytes += generator.hr();

    final items = data['items'] as List? ?? [];
    for (final item in items) {
      final name = item['name'] ?? '';
      final qty = item['quantity'] ?? 1;
      final price = (item['price'] is num) ? (item['price'] as num).toDouble() : 0.0;
      final total = price * qty;
      final qtyStr = qty > 1 ? ' x$qty' : '';
      bytes += generator.row([
        PosColumn(text: '$name$qtyStr', width: 8, styles: const PosStyles(bold: true)),
        PosColumn(text: '\$${total.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right, bold: true)),
      ]);
    }

    bytes += generator.hr();
    bytes += generator.feed(1);

    if (format['showTaxBreakdown'] == true) {
      final subtotal = (data['subtotal'] is num) ? (data['subtotal'] as num).toDouble() : 0.0;
      bytes += generator.row([
        PosColumn(text: '$lSubtotal:', width: 8),
        PosColumn(text: '\$${subtotal.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
      ]);
      final tax = (data['taxAmount'] is num) ? (data['taxAmount'] as num).toDouble() : 0.0;
      if (tax > 0) {
        bytes += generator.row([
          PosColumn(text: '$lTaxes:', width: 8),
          PosColumn(text: '\$${tax.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
        ]);
      }
      final discount = (data['discountAmount'] is num) ? (data['discountAmount'] as num).toDouble() : 0.0;
      if (discount > 0) {
        bytes += generator.row([
          PosColumn(text: '$lDiscount:', width: 8),
          PosColumn(text: '-\$${discount.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
        ]);
      }
      bytes += generator.feed(1);
    }

    bytes += generator.hr(ch: '=');
    final total = (data['total'] is num) ? (data['total'] as num).toDouble() : 0.0;
    // TOTAL in bold + double height using raw ESC/POS
    bytes += [0x1B, 0x45, 0x01]; // Bold ON
    bytes += [0x1D, 0x21, 0x01]; // Double height
    bytes += generator.row([
      PosColumn(text: '$lTotal:', width: 8),
      PosColumn(text: '\$${total.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
    ]);
    bytes += [0x1D, 0x21, 0x00]; // Normal size
    bytes += [0x1B, 0x45, 0x00]; // Bold OFF
    bytes += generator.hr(ch: '=');
    bytes += generator.feed(1);

    if (format['showPaymentMethod'] == true) {
      final paidAmount = (data['paidAmount'] is num) ? (data['paidAmount'] as num).toDouble() : 0.0;
      final changeAmount = (data['changeAmount'] is num) ? (data['changeAmount'] as num).toDouble() : 0.0;
      bytes += generator.row([
        PosColumn(text: '$lMethod:', width: 8),
        PosColumn(text: paymentMethods[data['paymentMethod']] ?? '', width: 4, styles: const PosStyles(align: PosAlign.right)),
      ]);
      bytes += generator.row([
        PosColumn(text: '$lPaid:', width: 8),
        PosColumn(text: '\$${paidAmount.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
      ]);
      if (changeAmount > 0) {
        bytes += generator.row([
          PosColumn(text: '$lChange:', width: 8),
          PosColumn(text: '\$${changeAmount.toStringAsFixed(2)}', width: 4, styles: const PosStyles(align: PosAlign.right)),
        ]);
      }
    }

    bytes += generator.feed(1);
    bytes += generator.hr();
    bytes += generator.setStyles(const PosStyles(align: PosAlign.center));
    bytes += generator.text(format['footerMessage'] ?? '');
    if ((format['footerLine2'] ?? '').isNotEmpty) {
      bytes += generator.feed(1);
      bytes += generator.text(format['footerLine2']);
    }
    if ((format['footerLine3'] ?? '').isNotEmpty) {
      bytes += generator.feed(1);
      bytes += generator.text(format['footerLine3']);
    }
    bytes += generator.hr(ch: '=');
    bytes += generator.feed(3);
    if (format['autoCut'] == true) bytes += generator.cut();
    if (format['openDrawer'] == true && data['paymentMethod'] == 'CASH') bytes += generator.drawer();

    return bytes;
  }

  /// Build ESC/POS bytes for a test print
  Future<List<int>> _buildTestBytes(Map<String, dynamic> data) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    bytes += generator.setStyles(const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2));
    bytes += generator.text('PRUEBA');
    bytes += generator.setStyles(const PosStyles(align: PosAlign.center));
    bytes += generator.hr(ch: '=');
    bytes += generator.text('Ticket Ventas Print');
    bytes += generator.feed(1);
    bytes += generator.text('Impresion de prueba exitosa');
    bytes += generator.feed(1);
    bytes += generator.text(DateTime.now().toString().substring(0, 19));
    bytes += generator.hr(ch: '=');
    bytes += generator.feed(3);
    bytes += generator.cut();

    return bytes;
  }

  /// Send raw bytes to the configured printer
  Future<void> _sendToPrinter(List<int> bytes) async {
    if (_printerType == 'NETWORK' && _printerAddress != null) {
      await _sendToNetworkPrinter(bytes);
    } else if (_printerType == 'USB') {
      await _sendToUsbPrinter(bytes);
    } else {
      throw Exception('Impresora no configurada');
    }
  }

  /// Send to network printer via TCP raw (port 9100)
  Future<void> _sendToNetworkPrinter(List<int> bytes) async {
    final parts = _printerAddress!.split(':');
    final host = parts[0];
    final port = parts.length > 1 ? int.parse(parts[1]) : 9100;

    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 10));
    socket.add(Uint8List.fromList(bytes));
    await socket.flush();
    await socket.close();
  }

  /// Send to USB printer via OS
  Future<void> _sendToUsbPrinter(List<int> bytes) async {
    final tempFile = File(_getTempPath());
    await tempFile.writeAsBytes(bytes);

    try {
      if (Platform.isWindows) {
        await _printWindowsUsb(tempFile);
      } else if (Platform.isLinux) {
        await _printLinux(tempFile);
      } else if (Platform.isMacOS) {
        await _printMacOS(tempFile);
      }
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  String _getTempPath() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    if (Platform.isWindows) {
      return '${Directory.systemTemp.path}\\tvprint_$timestamp.bin';
    }
    return '/tmp/tvprint_$timestamp.bin';
  }

  /// Windows: Send raw bytes to printer using Windows Spooler API via PowerShell
  Future<void> _printWindowsUsb(File tempFile) async {
    final printerName = _printerName ?? '';

    // Use .NET RawPrinterHelper to send raw bytes to the printer spooler
    final result = await Process.run('powershell', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
      '''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class RawPrinter {
    [StructLayout(LayoutKind.Sequential)]
    public struct DOCINFOA { public string pDocName; public string pOutputFile; public string pDatatype; }

    [DllImport("winspool.drv", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool StartDocPrinter(IntPtr hPrinter, int Level, ref DOCINFOA pDocInfo);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool StartPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool WritePrinter(IntPtr hPrinter, byte[] pBytes, int dwCount, out int dwWritten);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool EndPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool EndDocPrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool ClosePrinter(IntPtr hPrinter);

    public static bool SendRaw(string printerName, byte[] data) {
        IntPtr hPrinter;
        if (!OpenPrinter(printerName, out hPrinter, IntPtr.Zero)) return false;
        var di = new DOCINFOA { pDocName = "TicketVentas Receipt", pDatatype = "RAW" };
        if (!StartDocPrinter(hPrinter, 1, ref di)) { ClosePrinter(hPrinter); return false; }
        StartPagePrinter(hPrinter);
        int written;
        WritePrinter(hPrinter, data, data.Length, out written);
        EndPagePrinter(hPrinter);
        EndDocPrinter(hPrinter);
        ClosePrinter(hPrinter);
        return true;
    }
}
"@
\$bytes = [System.IO.File]::ReadAllBytes("${tempFile.path.replaceAll('\\', '\\\\')}");
\$result = [RawPrinter]::SendRaw("$printerName", \$bytes);
if (\$result) { Write-Output "OK" } else { Write-Output "FAILED" }
'''
    ]);

    final output = (result.stdout as String).trim();
    if (!output.contains('OK')) {
      throw Exception('Error imprimiendo en "$printerName": $output ${result.stderr}');
    }
  }

  /// Linux: Use lp command or write to /dev/usb/lp0
  Future<void> _printLinux(File tempFile) async {
    final devPath = File('/dev/usb/lp0');
    if (await devPath.exists()) {
      final bytes = await tempFile.readAsBytes();
      await devPath.writeAsBytes(bytes);
    } else if (_printerName != null) {
      await Process.run('lp', ['-d', _printerName!, '-o', 'raw', tempFile.path]);
    } else {
      await Process.run('lp', ['-o', 'raw', tempFile.path]);
    }
  }

  /// macOS: Use lp command
  Future<void> _printMacOS(File tempFile) async {
    if (_printerName != null) {
      await Process.run('lp', ['-d', _printerName!, '-o', 'raw', tempFile.path]);
    } else {
      await Process.run('lp', ['-o', 'raw', tempFile.path]);
    }
  }

  /// Get cached logo file (downloads once, reuses from disk)
  static String? _cachedLogoUrl;
  static File? _cachedLogoFile;

  Future<File?> _getCachedLogo(String logoUrl) async {
    final cacheDir = Directory('${Directory.systemTemp.path}/ticketventas_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final logoPath = '${cacheDir.path}/logo.png';
    final logoFile = File(logoPath);

    // If same URL and file exists, use cache
    if (_cachedLogoUrl == logoUrl && await logoFile.exists()) {
      return logoFile;
    }

    // Download and cache
    try {
      final response = await http.get(Uri.parse(logoUrl));
      if (response.statusCode == 200) {
        await logoFile.writeAsBytes(response.bodyBytes);
        _cachedLogoUrl = logoUrl;
        _cachedLogoFile = logoFile;
        return logoFile;
      }
    } catch (_) {}
    return null;
  }
}
