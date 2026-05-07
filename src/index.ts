/**
 * Ticketasy Print Relay Agent
 * Main entry point
 *
 * Usage:
 *   First time:  ticketasy-print-relay --activate ABC-XY7-9KM [--server wss://...]
 *   Normal run:  ticketasy-print-relay
 *   Configure:   ticketasy-print-relay --printer network 192.168.1.100:9100
 *                ticketasy-print-relay --printer usb
 *   Reset:       ticketasy-print-relay --reset
 */

import { connect, activateWithCode, disconnect, isConnected } from './connection.js';
import { getConfig, isActivated, savePrinterConfig, saveServerUrl, clearConfig } from './config.js';
import { log } from './logger.js';

const VERSION = '1.0.0';

function printBanner(): void {
  console.log('');
  console.log('  ╔══════════════════════════════════════╗');
  console.log('  ║   🖨️  Ticketasy Print Relay v' + VERSION + '  ║');
  console.log('  ╚══════════════════════════════════════╝');
  console.log('');
}

function printHelp(): void {
  console.log('Uso:');
  console.log('  ticketasy-print-relay                          Iniciar relay (requiere activación previa)');
  console.log('  ticketasy-print-relay --activate CODE          Activar con código del panel');
  console.log('  ticketasy-print-relay --server URL             Configurar URL del servidor');
  console.log('  ticketasy-print-relay --printer network IP:PORT  Configurar impresora de red');
  console.log('  ticketasy-print-relay --printer usb            Configurar impresora USB');
  console.log('  ticketasy-print-relay --status                 Ver estado actual');
  console.log('  ticketasy-print-relay --reset                  Borrar configuración');
  console.log('  ticketasy-print-relay --help                   Mostrar esta ayuda');
  console.log('');
}

function printStatus(): void {
  const config = getConfig();
  console.log('Estado actual:');
  console.log(`  Activado:    ${isActivated() ? '✅ Sí' : '❌ No'}`);
  console.log(`  Servidor:    ${config.serverUrl}`);
  console.log(`  Estación:    ${config.stationId || 'N/A'}`);
  console.log(`  Impresora:   ${config.printerType || 'No configurada'}`);
  if (config.printerType === 'NETWORK') {
    console.log(`  Dirección:   ${config.printerAddress}`);
  }
  if (config.printerName) {
    console.log(`  Nombre:      ${config.printerName}`);
  }
  console.log(`  Conectado:   ${isConnected() ? '✅ Sí' : '❌ No'}`);
  console.log('');
}

async function main(): Promise<void> {
  printBanner();

  const args = process.argv.slice(2);

  // --help
  if (args.includes('--help') || args.includes('-h')) {
    printHelp();
    process.exit(0);
  }

  // --reset
  if (args.includes('--reset')) {
    clearConfig();
    log('info', 'Configuración borrada. Necesitas activar de nuevo.');
    process.exit(0);
  }

  // --status
  if (args.includes('--status')) {
    printStatus();
    process.exit(0);
  }

  // --server URL
  const serverIdx = args.indexOf('--server');
  if (serverIdx !== -1 && args[serverIdx + 1]) {
    saveServerUrl(args[serverIdx + 1]);
    log('info', `Servidor configurado: ${args[serverIdx + 1]}`);
    if (!args.includes('--activate')) {
      process.exit(0);
    }
  }

  // --printer network IP:PORT | --printer usb
  const printerIdx = args.indexOf('--printer');
  if (printerIdx !== -1) {
    const type = args[printerIdx + 1];
    if (type === 'network') {
      const address = args[printerIdx + 2];
      if (!address) {
        log('error', 'Falta la dirección IP:PUERTO. Ejemplo: --printer network 192.168.1.100:9100');
        process.exit(1);
      }
      savePrinterConfig({ printerType: 'NETWORK', printerAddress: address });
      log('info', `Impresora de red configurada: ${address}`);
    } else if (type === 'usb') {
      savePrinterConfig({ printerType: 'USB' });
      log('info', 'Impresora USB configurada');
    } else {
      log('error', 'Tipo de impresora inválido. Usa: network o usb');
      process.exit(1);
    }
    process.exit(0);
  }

  // --activate CODE
  const activateIdx = args.indexOf('--activate');
  if (activateIdx !== -1) {
    const code = args[activateIdx + 1];
    if (!code) {
      log('error', 'Falta el código de activación. Ejemplo: --activate ABC-XY7-9KM');
      process.exit(1);
    }

    const config = getConfig();
    const success = await activateWithCode(code, config.serverUrl);
    if (success) {
      log('info', 'Activación exitosa. Iniciando relay...');
      // Continue to connect
    } else {
      log('error', 'Activación fallida. Verifica el código e intenta de nuevo.');
      process.exit(1);
    }
  }

  // Normal start — verify activation
  if (!isActivated()) {
    log('error', 'No activado. Usa: --activate CODIGO');
    log('info', 'Obtén el código desde el panel de Ticketasy > Configuración > Impresión');
    process.exit(1);
  }

  // Verify printer is configured
  const config = getConfig();
  if (!config.printerType) {
    log('warn', '⚠️  No hay impresora configurada. Configura una con:');
    log('info', '  --printer network IP:PUERTO  (para impresoras de red)');
    log('info', '  --printer usb                (para impresoras USB)');
    log('info', '');
    log('info', 'Iniciando de todas formas (recibirás errores al imprimir)...');
  }

  // Connect
  connect();

  // Status display
  log('info', `Estación: ${config.stationId}`);
  log('info', `Impresora: ${config.printerType || 'No configurada'} ${config.printerAddress || ''}`);
  log('info', 'Esperando trabajos de impresión...');
  log('info', 'Presiona Ctrl+C para detener');

  // Graceful shutdown
  process.on('SIGINT', () => {
    log('info', 'Deteniendo...');
    disconnect();
    process.exit(0);
  });

  process.on('SIGTERM', () => {
    log('info', 'Deteniendo...');
    disconnect();
    process.exit(0);
  });

  // Keep process alive
  setInterval(() => {}, 60000);
}

main().catch((err) => {
  log('error', `Fatal error: ${err.message}`);
  process.exit(1);
});
