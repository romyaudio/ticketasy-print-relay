import 'dart:io';
import 'dart:typed_data';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;

class PrinterService {
  String? _printerType; // 'NETWORK', 'USB', or 'STANDARD'
  String? _printerAddress; // IP:port for network
  String? _printerName; // OS printer name for USB/STANDARD

  void configure({
    required String type,
    String? address,
    String? name,
  }) {
    _printerType = type;
    _printerAddress = address;
    _printerName = name;
  }

  bool get isConfigured => _printerType != null && _printerType!.isNotEmpty;
  bool get isThermal => _printerType == 'USB' || _printerType == 'NETWORK';
  bool get isStandard => _printerType == 'STANDARD';

  /// Print a receipt
  Future<void> printReceipt(Map<String, dynamic> data, Map<String, dynamic> format) async {
    if (isStandard) {
      await _printStandardReceipt(data, format);
    } else {
      final bytes = await _buildReceiptBytes(data, format);
      await _sendToPrinter(bytes);
    }
  }

  /// Print a test page
  Future<void> printTest(Map<String, dynamic> data) async {
    if (isStandard) {
      await _printStandardTest(data);
    } else {
      final bytes = await _buildTestBytes(data);
      await _sendToPrinter(bytes);
    }
  }

  /// Open cash drawer only (no print) - only for thermal
  Future<void> openDrawer() async {
    if (isStandard) return; // Standard printers don't have drawers
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

  // ===========================================================================
  // STANDARD PRINTER (HTML-based printing for normal printers)
  // ===========================================================================

  /// Print receipt on a standard printer via HTML
  Future<void> _printStandardReceipt(Map<String, dynamic> data, Map<String, dynamic> format) async {
    final html = _buildReceiptHtml(data, format);
    await _printHtml(html);
  }

  /// Print test page on a standard printer
  Future<void> _printStandardTest(Map<String, dynamic> data) async {
    final html = '''<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>@page{size:80mm auto;margin:5mm}*{margin:0;padding:0;box-sizing:border-box}
body{font:12px system-ui,sans-serif;width:100%;padding:3mm}
.c{text-align:center}.b{font-weight:bold}.big{font-size:18px}
.sep{border-top:1px dashed #000;margin:8px 0}</style></head><body>
<div class="c big b">PRUEBA DE IMPRESION</div>
<div class="sep"></div>
<div class="c">Ticket Ventas Print</div>
<div class="c" style="margin-top:8px">Impresion de prueba exitosa</div>
<div class="c" style="margin-top:8px">${DateTime.now().toString().substring(0, 19)}</div>
<div class="sep"></div>
<div class="c" style="font-size:10px;color:#666">Si puedes leer esto, la impresora esta configurada correctamente.</div>
</body></html>''';
    await _printHtml(html);
  }

  /// Build HTML for a receipt (used by standard printers)
  String _buildReceiptHtml(Map<String, dynamic> data, Map<String, dynamic> format) {
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

    final createdAt = (DateTime.tryParse(data['createdAt'] ?? '') ?? DateTime.now()).toLocal();
    final hour = createdAt.hour > 12 ? createdAt.hour - 12 : (createdAt.hour == 0 ? 12 : createdAt.hour);
    final ampm = createdAt.hour >= 12 ? 'PM' : 'AM';
    final dateStr = '${createdAt.day.toString().padLeft(2, '0')}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.year}';
    final timeStr = '$hour:${createdAt.minute.toString().padLeft(2, '0')} $ampm';

    final items = data['items'] as List? ?? [];
    final total = (data['total'] is num) ? (data['total'] as num).toDouble() : 0.0;
    final subtotal = (data['subtotal'] is num) ? (data['subtotal'] as num).toDouble() : 0.0;
    final taxAmount = (data['taxAmount'] is num) ? (data['taxAmount'] as num).toDouble() : 0.0;
    final discountAmount = (data['discountAmount'] is num) ? (data['discountAmount'] as num).toDouble() : 0.0;
    final paidAmount = (data['paidAmount'] is num) ? (data['paidAmount'] as num).toDouble() : 0.0;
    final changeAmount = (data['changeAmount'] is num) ? (data['changeAmount'] as num).toDouble() : 0.0;

    final buf = StringBuffer();
    buf.write('<!DOCTYPE html><html><head><meta charset="UTF-8">');
    buf.write('<style>@page{size:80mm auto;margin:5mm}');
    buf.write('*{margin:0;padding:0;box-sizing:border-box;color:#000}');
    buf.write('body{font:12px system-ui,sans-serif;width:100%;padding:3mm}');
    buf.write('table{width:100%;border-collapse:collapse}td{padding:2px 0;vertical-align:top}');
    buf.write('.sep{border-top:1px dashed #000;margin:6px 0}');
    buf.write('.r{text-align:right}.c{text-align:center}.b{font-weight:bold}.big{font-size:14px}');
    buf.write('</style></head><body>');

    // Header
    buf.write('<div class="c">');
    if (format['showLogo'] == true && data['companyLogo'] != null && (data['companyLogo'] as String).isNotEmpty) {
      buf.write('<img src="${data['companyLogo']}" style="width:60px;height:60px;object-fit:contain;margin:0 auto 6px;display:block">');
    }
    buf.write('<div class="b big">${data['companyName'] ?? ''}</div>');
    if (format['showAddress'] == true && data['companyAddress'] != null) {
      buf.write('<div style="font-size:10px">${data['companyAddress']}</div>');
    }
    if (format['showPhone'] == true && data['companyPhone'] != null) {
      buf.write('<div style="font-size:10px">Tel: ${data['companyPhone']}</div>');
    }
    if (data['locationName'] != null && (data['locationName'] as String).isNotEmpty) {
      buf.write('<div style="font-size:10px">${data['locationName']}</div>');
    }
    buf.write('</div>');

    buf.write('<div class="sep"></div>');

    // Date, employee, order
    buf.write('<div style="font-size:11px">');
    buf.write('<div>$lDate: $dateStr &nbsp; $lTime: $timeStr</div>');
    if (format['showEmployee'] == true && data['employeeName'] != null) {
      buf.write('<div>$lServedBy: ${data['employeeName']}</div>');
    }
    if (format['showOrderNumber'] == true) {
      final orderId = data['orderId'] ?? '';
      buf.write('<div>$lOrder: #${orderId.length > 8 ? orderId.substring(orderId.length - 8) : orderId}</div>');
    }
    buf.write('</div>');

    buf.write('<div class="sep"></div>');

    // Items
    buf.write('<table>');
    for (final item in items) {
      final name = item['name'] ?? '';
      final qty = item['quantity'] ?? 1;
      final price = (item['price'] is num) ? (item['price'] as num).toDouble() : 0.0;
      final itemTotal = price * qty;
      final qtyStr = qty > 1 ? ' x$qty' : '';
      buf.write('<tr><td class="b">$name$qtyStr</td><td class="r b">\$${itemTotal.toStringAsFixed(2)}</td></tr>');
    }
    buf.write('</table>');

    buf.write('<div class="sep"></div>');

    // Totals
    if (format['showTaxBreakdown'] == true) {
      buf.write('<table>');
      buf.write('<tr><td>$lSubtotal</td><td class="r">\$${subtotal.toStringAsFixed(2)}</td></tr>');
      if (taxAmount > 0) buf.write('<tr><td>$lTaxes</td><td class="r">\$${taxAmount.toStringAsFixed(2)}</td></tr>');
      if (discountAmount > 0) buf.write('<tr><td>$lDiscount</td><td class="r">-\$${discountAmount.toStringAsFixed(2)}</td></tr>');
      buf.write('</table>');
    }

    buf.write('<div class="sep"></div>');
    buf.write('<table><tr class="b big"><td>$lTotal</td><td class="r">\$${total.toStringAsFixed(2)}</td></tr></table>');
    buf.write('<div class="sep"></div>');

    // Payment
    if (format['showPaymentMethod'] == true) {
      buf.write('<table>');
      buf.write('<tr><td>$lMethod</td><td class="r">${paymentMethods[data['paymentMethod']] ?? ''}</td></tr>');
      buf.write('<tr><td>$lPaid</td><td class="r">\$${paidAmount.toStringAsFixed(2)}</td></tr>');
      if (changeAmount > 0) buf.write('<tr><td class="b">$lChange</td><td class="r b">\$${changeAmount.toStringAsFixed(2)}</td></tr>');
      buf.write('</table>');
      buf.write('<div class="sep"></div>');
    }

    // Footer
    buf.write('<div class="c" style="font-size:11px;margin-top:6px">');
    buf.write(format['footerMessage'] ?? '');
    if ((format['footerLine2'] ?? '').isNotEmpty) buf.write('<br>${format['footerLine2']}');
    if ((format['footerLine3'] ?? '').isNotEmpty) buf.write('<br>${format['footerLine3']}');
    buf.write('</div>');

    buf.write('</body></html>');
    return buf.toString();
  }

  /// Print HTML content using the OS print system
  Future<void> _printHtml(String html) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempPath = Platform.isWindows
        ? '${Directory.systemTemp.path}\\tvprint_$timestamp.html'
        : '/tmp/tvprint_$timestamp.html';
    final tempFile = File(tempPath);
    await tempFile.writeAsString(html);

    try {
      if (Platform.isWindows) {
        await _printHtmlWindows(tempFile);
      } else if (Platform.isLinux) {
        await _printHtmlLinux(tempFile);
      } else if (Platform.isMacOS) {
        await _printHtmlMacOS(tempFile);
      }
    } finally {
      // Small delay to let the print spooler read the file
      await Future.delayed(const Duration(seconds: 3));
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  /// Windows: Print HTML using PowerShell and the default browser print
  Future<void> _printHtmlWindows(File tempFile) async {
    final printerName = _printerName ?? '';
    final filePath = tempFile.path.replaceAll('\\', '\\\\');

    final result = await Process.run('powershell', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
      '''
\$printer = "$printerName"
\$file = "$filePath"
# Use .NET to print HTML silently via WebBrowser control
Add-Type -AssemblyName System.Windows.Forms
\$wb = New-Object System.Windows.Forms.WebBrowser
\$wb.ScriptErrorsSuppressed = \$true
\$wb.Navigate(\$file)
while (\$wb.ReadyState -ne [System.Windows.Forms.WebBrowserReadyState]::Complete) {
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 50
}
Start-Sleep -Milliseconds 500
# Set default printer temporarily if specified
if (\$printer) {
  \$wmi = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name = '\$printer'"
  if (\$wmi) { \$wmi.SetDefaultPrinter() | Out-Null }
}
\$wb.ShowPrintDialog() | Out-Null
\$wb.Dispose()
Write-Output "OK"
'''
    ]);

    final output = (result.stdout as String).trim();
    if (!output.contains('OK') && (result.stderr as String).isNotEmpty) {
      throw Exception('Error imprimiendo: ${result.stderr}');
    }
  }

  /// Linux: Print HTML using lp with html filter or convert to PDF first
  Future<void> _printHtmlLinux(File tempFile) async {
    if (_printerName != null) {
      await Process.run('lp', ['-d', _printerName!, tempFile.path]);
    } else {
      await Process.run('lp', [tempFile.path]);
    }
  }

  /// macOS: Print HTML using lp
  Future<void> _printHtmlMacOS(File tempFile) async {
    if (_printerName != null) {
      await Process.run('lp', ['-d', _printerName!, tempFile.path]);
    } else {
      await Process.run('lp', [tempFile.path]);
    }
  }
}
