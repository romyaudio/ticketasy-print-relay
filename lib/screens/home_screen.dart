import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import '../services/relay_service.dart';
import '../services/config_service.dart';
import '../services/printer_discovery.dart';
import '../l10n/translations.dart';

class HomeScreen extends StatefulWidget {
  final RelayService relayService;
  final ConfigService configService;

  const HomeScreen({
    super.key,
    required this.relayService,
    required this.configService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _codeController = TextEditingController();
  final _addressController = TextEditingController();
  bool _activating = false;
  String? _activationError;

  // Printer discovery
  List<DiscoveredPrinter> _printers = [];
  List<DiscoveredPrinter> _networkPrinters = [];
  bool _loadingPrinters = true;
  bool _scanningNetwork = false;
  int _scanProgress = 0;
  DiscoveredPrinter? _selectedPrinter;
  bool _showManualIp = false;

  RelayService get _relay => widget.relayService;
  ConfigService get _config => widget.configService;

  @override
  void initState() {
    super.initState();
    _relay.addListener(_onRelayChange);
    _discoverPrinters();
  }

  @override
  void dispose() {
    _relay.removeListener(_onRelayChange);
    _codeController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  void _onRelayChange() {
    if (mounted) setState(() {});
  }

  Future<void> _discoverPrinters() async {
    setState(() { _loadingPrinters = true; });
    final printers = await PrinterDiscovery.listSystemPrinters();
    setState(() {
      _printers = printers;
      _loadingPrinters = false;
      final defaultPrinter = printers.where((p) => p.isDefault).firstOrNull;
      if (defaultPrinter != null) _selectedPrinter = defaultPrinter;
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

  Future<void> _handleActivate() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    // Validate printer selection
    if (_selectedPrinter == null && !_showManualIp) {
      setState(() { _activationError = t('setup.selectPrinter'); });
      return;
    }
    if (_showManualIp && _addressController.text.trim().isEmpty) {
      setState(() { _activationError = t('setup.enterIp'); });
      return;
    }

    setState(() { _activating = true; _activationError = null; });

    // Save printer config first
    if (_showManualIp) {
      await _config.savePrinterConfig(type: 'NETWORK', address: _addressController.text.trim());
      _relay.printerService.configure(type: 'NETWORK', address: _addressController.text.trim());
    } else if (_selectedPrinter!.type == 'NETWORK') {
      await _config.savePrinterConfig(type: 'NETWORK', address: _selectedPrinter!.address!);
      _relay.printerService.configure(type: 'NETWORK', address: _selectedPrinter!.address!);
    } else {
      await _config.savePrinterConfig(type: 'USB', name: _selectedPrinter!.name);
      _relay.printerService.configure(type: 'USB', name: _selectedPrinter!.name);
    }

    // Activate
    final result = await _relay.activate(
      serverUrl: _config.serverUrl,
      setupCode: code,
    );

    if (result != null) {
      await _config.saveActivation(
        connectionToken: result['connectionToken'],
        stationId: result['stationId'],
        companyId: result['companyId'],
        locationId: result['locationId'],
      );

      await launchAtStartup.enable();

      if (_relay.status != ConnectionStatus.connected) {
        _relay.connect(
          serverUrl: _config.serverUrl,
          token: result['connectionToken'],
        );
      }

      _codeController.clear();
      setState(() { _activating = false; });
      return;
    } else {
      _activationError = _relay.lastError;
    }

    setState(() { _activating = false; });
  }

  Future<void> _handleDisconnect() async {
    _relay.disconnect();
    await _config.clearAll();
    await launchAtStartup.disable();
    setState(() {});
  }

  Future<void> _showChangePrinterDialog() async {
    // Refresh printer list
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
                    const SizedBox(height: 8),
                    // Network option
                    if (_networkPrinters.isNotEmpty)
                      ..._networkPrinters.map((printer) {
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
                                Icon(Icons.wifi, size: 16, color: isSelected ? const Color(0xFF1227DA) : Colors.grey),
                                const SizedBox(width: 10),
                                Expanded(child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(printer.name, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                                    if (printer.address != null) Text(printer.address!, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                                  ],
                                )),
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('dialog.cancel')),
          ),
          ElevatedButton(
            onPressed: _selectedPrinter != null ? () async {
              if (_selectedPrinter!.type == 'NETWORK' && _selectedPrinter!.address != null) {
                await _config.savePrinterConfig(type: 'NETWORK', address: _selectedPrinter!.address!);
                _relay.printerService.configure(type: 'NETWORK', address: _selectedPrinter!.address!);
              } else {
                await _config.savePrinterConfig(type: 'USB', name: _selectedPrinter!.name);
                _relay.printerService.configure(type: 'USB', name: _selectedPrinter!.name);
              }
              if (mounted) {
                Navigator.pop(context);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${t('dialog.printerChanged')} ${_selectedPrinter!.name}'), duration: const Duration(seconds: 2)),
                );
              }
            } : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1227DA),
              foregroundColor: Colors.white,
            ),
            child: Text(t('dialog.save')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isActivated = _config.isActivated;
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                _buildHeader(theme),
                const SizedBox(height: 20),
                Expanded(
                  child: isActivated
                      ? _buildConnectedView(theme)
                      : _buildSetupView(theme),
                ),
                if (isActivated) _buildLogs(theme),
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
            Text(t('app.title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A1A2E))),
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
    switch (_relay.status) {
      case ConnectionStatus.connected:
        color = Colors.green;
        label = t('status.connected');
        break;
      case ConnectionStatus.connecting:
        color = Colors.orange;
        label = t('status.connecting');
        break;
      case ConnectionStatus.error:
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
  // SETUP VIEW (not activated)
  // =========================================================================

  Widget _buildSetupView(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step 1: Select printer
          _buildStepHeader('1', t('setup.step1'), theme),
          const SizedBox(height: 12),
          _buildPrinterSelection(theme),
          const SizedBox(height: 24),

          // Step 2: Enter code
          _buildStepHeader('2', t('setup.step2'), theme),
          const SizedBox(height: 12),
          _buildCodeInput(theme),
        ],
      ),
    );
  }

  Widget _buildStepHeader(String number, String title, ThemeData theme) {
    return Row(
      children: [
        Container(
          width: 24, height: 24,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            shape: BoxShape.circle,
          ),
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
          // System printers header
          Row(
            children: [
              const Icon(Icons.print, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Text(t('setup.detected'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4A4A6A))),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                onPressed: _discoverPrinters,
                tooltip: 'Actualizar',
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 8),

          // System printers list
          if (_loadingPrinters)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_printers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(t('setup.noprinters'), style: const TextStyle(color: Color(0xFF4A4A6A), fontSize: 12)),
            )
          else
            ...(_printers.map((printer) => _buildPrinterTile(printer, theme))),

          // Network printers section
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
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
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
          else if (_networkPrinters.isEmpty && !_scanningNetwork)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(t('setup.networkHint'), style: const TextStyle(color: Color(0xFF4A4A6A), fontSize: 11)),
            ),

          // Manual IP option
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

          // Compatibility note
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
                Expanded(
                  child: Text(
                    t('help.compatibility'),
                    style: const TextStyle(fontSize: 10, color: Colors.black87, height: 1.5),
                  ),
                ),
              ],
            ),
          ),

          // Help section
          const Divider(height: 24),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.help_outline, size: 14, color: Colors.amber),
                    const SizedBox(width: 6),
                    Text(t('help.title'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '• ${t('help.usb')}\n• ${t('help.wifi')}\n• ${t('help.manual')}',
                  style: const TextStyle(fontSize: 10, color: Colors.black87, height: 1.5),
                ),
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

  Widget _buildCodeInput(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border.all(color: Colors.blue.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('setup.codeInfo'), style: const TextStyle(fontSize: 12, color: Color(0xFF2A4A7A))),
          const SizedBox(height: 4),
          Text(t('setup.codePath'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: InputDecoration(
              hintText: t('setup.codeHint'),
              labelText: t('setup.codeLabel'),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              prefixIcon: const Icon(Icons.vpn_key, size: 18),
              filled: true,
              fillColor: Colors.white,
            ),
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9\-]'))],
          ),
          const SizedBox(height: 10),

          if (_activationError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_activationError!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _activating ? null : _handleActivate,
              icon: _activating
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.link),
              label: Text(_activating ? t('setup.connecting') : t('setup.connect')),
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
  // CONNECTED VIEW
  // =========================================================================

  Widget _buildConnectedView(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Text(t('connected.title'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${t('connected.printer')}: ${_config.printerName ?? _config.printerAddress ?? t('printer.configured')}', style: const TextStyle(fontSize: 12, color: Color(0xFF4A4A6A))),
                Text('${t('connected.station')}: ${_config.stationId ?? "N/A"}', style: const TextStyle(fontSize: 11, color: Color(0xFF4A4A6A))),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Change printer button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _showChangePrinterDialog,
              icon: const Icon(Icons.print, size: 18),
              label: Text(t('connected.changePrinter')),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1227DA),
                side: const BorderSide(color: Color(0xFF1227DA)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Disconnect
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _handleDisconnect,
              icon: const Icon(Icons.link_off, size: 18),
              label: Text(t('connected.disconnect')),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // LOGS
  // =========================================================================

  Widget _buildLogs(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle_outline, color: Colors.green, size: 32),
          const SizedBox(height: 10),
          Text(
            t('connected.success.title'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1A1A2E)),
          ),
          const SizedBox(height: 6),
          Text(
            t('connected.success.message'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF4A4A6A)),
          ),
          const SizedBox(height: 8),
          Text(
            t('connected.success.hint'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6A6A8A)),
          ),
        ],
      ),
    );
  }
}
