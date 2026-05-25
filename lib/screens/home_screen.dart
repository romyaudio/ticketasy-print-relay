import 'dart:io';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import '../services/local_server.dart';
import '../services/config_service.dart';
import '../services/printer_discovery.dart';
import '../l10n/translations.dart';

class HomeScreen extends StatefulWidget {
  final LocalPrintServer server;
  final ConfigService configService;

  const HomeScreen({
    super.key,
    required this.server,
    required this.configService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Printer discovery
  List<DiscoveredPrinter> _printers = [];
  List<DiscoveredPrinter> _networkPrinters = [];
  bool _loadingPrinters = true;
  bool _scanningNetwork = false;
  int _scanProgress = 0;
  DiscoveredPrinter? _selectedPrinter;
  bool _showManualIp = false;
  String _printerMode = 'THERMAL'; // 'THERMAL' or 'STANDARD'
  final _addressController = TextEditingController();

  LocalPrintServer get _server => widget.server;
  ConfigService get _config => widget.configService;

  @override
  void initState() {
    super.initState();
    _server.addListener(_onServerChange);
    _discoverPrinters();
  }

  @override
  void dispose() {
    _server.removeListener(_onServerChange);
    _addressController.dispose();
    super.dispose();
  }

  void _onServerChange() {
    if (mounted) setState(() {});
  }

  Future<void> _discoverPrinters() async {
    setState(() { _loadingPrinters = true; });
    final printers = await PrinterDiscovery.listSystemPrinters();
    setState(() {
      _printers = printers;
      _loadingPrinters = false;
      // Auto-select configured printer or default
      if (_config.printerName != null) {
        _selectedPrinter = printers.where((p) => p.name == _config.printerName).firstOrNull;
      }
      _selectedPrinter ??= printers.where((p) => p.isDefault).firstOrNull;
    });
  }

  Future<void> _scanNetwork() async {
    setState(() { _scanningNetwork = true; _scanProgress = 0; _networkPrinters = []; });
    final printers = await PrinterDiscovery.scanNetworkPrinters(
      onProgress: (scanned, total) {
        setState(() { _scanProgress = ((scanned / total) * 100).round(); });
      },
    );
    setState(() { _networkPrinters = printers; _scanningNetwork = false; });
  }

  Future<void> _savePrinter() async {
    if (_showManualIp && _addressController.text.trim().isNotEmpty) {
      await _config.savePrinterConfig(type: 'NETWORK', address: _addressController.text.trim());
      _server.printerService.configure(type: 'NETWORK', address: _addressController.text.trim());
    } else if (_selectedPrinter != null) {
      if (_printerMode == 'STANDARD') {
        // Standard printer (HTML-based)
        await _config.savePrinterConfig(type: 'STANDARD', name: _selectedPrinter!.name);
        _server.printerService.configure(type: 'STANDARD', name: _selectedPrinter!.name);
      } else if (_selectedPrinter!.type == 'NETWORK' && _selectedPrinter!.address != null) {
        await _config.savePrinterConfig(type: 'NETWORK', address: _selectedPrinter!.address!);
        _server.printerService.configure(type: 'NETWORK', address: _selectedPrinter!.address!);
      } else {
        await _config.savePrinterConfig(type: 'USB', name: _selectedPrinter!.name);
        _server.printerService.configure(type: 'USB', name: _selectedPrinter!.name);
      }
    }
    await launchAtStartup.enable();
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('dialog.printerChanged')), duration: const Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPrinter = _server.printerService.isConfigured;

    return Scaffold(
      body: Container(
        color: Colors.white,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                _buildHeader(theme),
                const SizedBox(height: 20),
                Expanded(
                  child: hasPrinter
                      ? _buildRunningView(theme)
                      : _buildSetupView(theme),
                ),
                _buildLogs(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.print, color: theme.colorScheme.primary, size: 28),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${t('app.title')} v$agentVersion', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A1A2E))),
            Text(t('app.subtitle'), style: const TextStyle(fontSize: 12, color: Color(0xFF4A4A6A))),
          ],
        ),
        const Spacer(),
        _buildStatusBadge(),
      ],
    );
  }

  Widget _buildStatusBadge() {
    Color color;
    String label;
    switch (_server.status) {
      case ServerStatus.running:
        color = Colors.green;
        label = t('status.connected');
        break;
      case ServerStatus.error:
        color = Colors.red;
        label = t('status.error');
        break;
      default:
        color = Colors.grey;
        label = t('status.disconnected');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // =========================================================================
  // SETUP VIEW (no printer configured)
  // =========================================================================

  Widget _buildSetupView(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStepHeader('1', t('setup.step1'), theme),
          const SizedBox(height: 12),
          _buildPrinterSelection(theme),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_selectedPrinter != null || (_showManualIp && _addressController.text.trim().isNotEmpty))
                  ? _savePrinter
                  : null,
              icon: const Icon(Icons.save),
              label: Text(t('dialog.save')),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1227DA),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // RUNNING VIEW (printer configured, server running)
  // =========================================================================

  Widget _buildRunningView(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Update banner
          if (_server.updateAvailable != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: Row(
                children: [
                  const Icon(Icons.system_update, size: 18, color: Colors.orange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${t('update.available')} v${_server.updateAvailable}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1A1A2E)),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Process.run('cmd', ['/c', 'start', 'https://github.com/romyaudio/ticketasy-print-relay/releases/latest']);
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                    child: Text(t('update.download'), style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),

          // Status card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _server.isRunning ? Colors.green.shade50 : Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _server.isRunning ? Colors.green.shade200 : Colors.red.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _server.isRunning ? Icons.check_circle : Icons.error,
                      color: _server.isRunning ? Colors.green : Colors.red,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _server.isRunning ? t('connected.title') : t('status.error'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${t('connected.printer')}: ${_config.printerName ?? _config.printerAddress ?? t('printer.configured')}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF4A4A6A)),
                ),
                Text(
                  'Puerto: ${_server.port} • Clientes: ${_server.activeConnections}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF4A4A6A)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Actions
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showChangePrinterDialog(),
                  icon: const Icon(Icons.print, size: 16),
                  label: Text(t('connected.changePrinter'), style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _server.stop();
                    await _config.clearAll();
                    await launchAtStartup.disable();
                    _server.printerService.configure(type: '', name: null, address: null);
                    setState(() {});
                  },
                  icon: const Icon(Icons.link_off, size: 16, color: Colors.red),
                  label: Text(t('connected.disconnect'), style: const TextStyle(fontSize: 12, color: Colors.red)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    side: const BorderSide(color: Colors.red),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Info box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('connected.success.message'),
                    style: const TextStyle(fontSize: 11, color: Colors.black87, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // SHARED WIDGETS
  // =========================================================================

  Widget _buildStepHeader(String number, String title, ThemeData theme) {
    return Row(
      children: [
        Container(
          width: 24, height: 24,
          decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
          child: Center(child: Text(number, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
        ),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1A1A2E))),
      ],
    );
  }

  Widget _buildPrinterSelection(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Printer mode selector
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() { _printerMode = 'THERMAL'; }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _printerMode == 'THERMAL' ? const Color(0xFF1227DA).withValues(alpha: 0.1) : Colors.transparent,
                      border: Border.all(color: _printerMode == 'THERMAL' ? const Color(0xFF1227DA) : Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.receipt_long, size: 20, color: _printerMode == 'THERMAL' ? const Color(0xFF1227DA) : Colors.grey),
                        const SizedBox(height: 4),
                        Text(t('setup.thermal'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _printerMode == 'THERMAL' ? const Color(0xFF1227DA) : Colors.grey)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() { _printerMode = 'STANDARD'; }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _printerMode == 'STANDARD' ? const Color(0xFF1227DA).withValues(alpha: 0.1) : Colors.transparent,
                      border: Border.all(color: _printerMode == 'STANDARD' ? const Color(0xFF1227DA) : Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.print, size: 20, color: _printerMode == 'STANDARD' ? const Color(0xFF1227DA) : Colors.grey),
                        const SizedBox(height: 4),
                        Text(t('setup.standard'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _printerMode == 'STANDARD' ? const Color(0xFF1227DA) : Colors.grey)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.print, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Text(t('setup.detected'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4A4A6A))),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _discoverPrinters,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loadingPrinters)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_printers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(t('setup.noprinters'), style: const TextStyle(color: Color(0xFF4A4A6A), fontSize: 12)),
            )
          else
            ...(_printers.map((printer) => _buildPrinterTile(printer, theme))),

          const Divider(height: 24),
          Row(
            children: [
              const Icon(Icons.wifi, size: 16, color: Colors.blue),
              const SizedBox(width: 6),
              Text(t('setup.network'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4A4A6A))),
              const Spacer(),
              if (!_scanningNetwork)
                TextButton.icon(
                  onPressed: _scanNetwork,
                  icon: const Icon(Icons.search, size: 14),
                  label: Text(t('setup.networkSearch'), style: const TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_scanningNetwork)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _scanProgress / 100),
                  const SizedBox(height: 4),
                  Text('${t('setup.networkScanning')} $_scanProgress%', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            )
          else if (_networkPrinters.isNotEmpty)
            ...(_networkPrinters.map((printer) => _buildPrinterTile(printer, theme)))
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(t('setup.networkHint'), style: const TextStyle(color: Color(0xFF4A4A6A), fontSize: 11)),
            ),

          const Divider(height: 24),
          GestureDetector(
            onTap: () => setState(() { _showManualIp = !_showManualIp; _selectedPrinter = null; }),
            child: Row(
              children: [
                Icon(_showManualIp ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                Text(t('setup.manualIp'), style: const TextStyle(fontSize: 11, color: Color(0xFF4A4A6A))),
              ],
            ),
          ),
          if (_showManualIp) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _addressController,
              decoration: InputDecoration(
                hintText: '192.168.1.100:9100',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                prefixIcon: const Icon(Icons.lan, size: 16),
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ],

          const Divider(height: 24),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.blue),
                const SizedBox(width: 6),
                Expanded(child: Text(t('help.compatibility'), style: const TextStyle(fontSize: 10, color: Colors.black87, height: 1.5))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrinterTile(DiscoveredPrinter printer, ThemeData theme) {
    final isSelected = _selectedPrinter?.name == printer.name && _selectedPrinter?.address == printer.address;
    final icon = printer.type == 'NETWORK' ? Icons.wifi : Icons.usb;
    return GestureDetector(
      onTap: () => setState(() { _selectedPrinter = printer; _showManualIp = false; }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary.withValues(alpha: 0.08) : Colors.transparent,
          border: Border.all(color: isSelected ? theme.colorScheme.primary : Colors.grey.shade200),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: isSelected ? theme.colorScheme.primary : Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(printer.name, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                  if (printer.address != null)
                    Text(printer.address!, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
            if (printer.isDefault)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(4)),
                child: const Text('Default', style: TextStyle(fontSize: 9, color: Colors.green)),
              ),
            if (isSelected)
              Icon(Icons.check_circle, size: 16, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }

  Widget _buildLogs(ThemeData theme) {
    final logs = _server.logs;
    if (logs.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 120,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        reverse: true,
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[logs.length - 1 - index];
          return Text(log, style: const TextStyle(fontSize: 10, color: Color(0xFF8888AA), fontFamily: 'Consolas', height: 1.5));
        },
      ),
    );
  }

  Future<void> _showChangePrinterDialog() async {
    await _discoverPrinters();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('dialog.changePrinter'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 350,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('dialog.selectNew'), style: const TextStyle(fontSize: 13, color: Color(0xFF4A4A6A))),
                    const SizedBox(height: 12),
                    if (_loadingPrinters)
                      const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    else if (_printers.isEmpty)
                      Text(t('setup.noprinters'), style: const TextStyle(color: Colors.grey, fontSize: 12))
                    else
                      ..._printers.map((printer) {
                        final isSelected = _selectedPrinter?.name == printer.name;
                        return GestureDetector(
                          onTap: () => setDialogState(() { _selectedPrinter = printer; }),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF1227DA).withValues(alpha: 0.08) : Colors.transparent,
                              border: Border.all(color: isSelected ? const Color(0xFF1227DA) : Colors.grey.shade200),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.print, size: 16, color: isSelected ? const Color(0xFF1227DA) : Colors.grey),
                                const SizedBox(width: 10),
                                Expanded(child: Text(printer.name, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal))),
                                if (isSelected) const Icon(Icons.check_circle, size: 16, color: Color(0xFF1227DA)),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t('dialog.cancel'))),
          ElevatedButton(
            onPressed: _selectedPrinter != null ? () async {
              await _savePrinter();
              if (mounted) Navigator.pop(context);
            } : null,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1227DA), foregroundColor: Colors.white),
            child: Text(t('dialog.save')),
          ),
        ],
      ),
    );
  }
}
