/**
 * Printer Manager
 * Handles sending ESC/POS data to USB or network printers
 */

import net from 'net';
import { getConfig } from './config.js';
import { formatReceipt, formatTestPrint } from './escpos-formatter.js';
import { sendPrintCompleted, sendPrintError } from './connection.js';
import { log } from './logger.js';

/**
 * Send raw bytes to a network printer via TCP
 */
async function sendToNetworkPrinter(address: string, data: Buffer): Promise<void> {
  return new Promise((resolve, reject) => {
    const [host, portStr] = address.split(':');
    const port = parseInt(portStr || '9100', 10);

    const socket = new net.Socket();
    socket.setTimeout(10000); // 10 second timeout

    socket.connect(port, host, () => {
      socket.write(data, () => {
        socket.end();
        resolve();
      });
    });

    socket.on('timeout', () => {
      socket.destroy();
      reject(new Error(`Connection timeout to ${host}:${port}`));
    });

    socket.on('error', (err) => {
      reject(new Error(`Network printer error: ${err.message}`));
    });
  });
}

/**
 * Send raw bytes to a USB printer
 * Uses escpos-usb if available, falls back to writing to device path
 */
async function sendToUsbPrinter(data: Buffer): Promise<void> {
  try {
    // Try using escpos-usb
    const { USB } = await import('escpos-usb');
    const device = new USB();

    return new Promise((resolve, reject) => {
      device.open((err: any) => {
        if (err) {
          reject(new Error(`USB open error: ${err.message}`));
          return;
        }
        device.write(data, (writeErr: any) => {
          device.close();
          if (writeErr) {
            reject(new Error(`USB write error: ${writeErr.message}`));
          } else {
            resolve();
          }
        });
      });
    });
  } catch (importErr) {
    throw new Error('USB printing not available. Install escpos-usb or use a network printer.');
  }
}

/**
 * Send data to the configured printer
 */
async function printRaw(data: Buffer): Promise<void> {
  const config = getConfig();

  if (config.printerType === 'NETWORK' && config.printerAddress) {
    await sendToNetworkPrinter(config.printerAddress, data);
  } else if (config.printerType === 'USB') {
    await sendToUsbPrinter(data);
  } else {
    throw new Error('No printer configured. Set printer type and address.');
  }
}

/**
 * Handle a print job from the backend
 */
export async function handlePrintJob(receiptData: any, format: any): Promise<void> {
  try {
    log('info', `Printing receipt for order ${receiptData.orderId}...`);

    const escposData = formatReceipt(receiptData, format);
    await printRaw(escposData);

    log('info', '✅ Receipt printed successfully');
    sendPrintCompleted();
  } catch (err: any) {
    log('error', `❌ Print failed: ${err.message}`);
    sendPrintError(err.message);
  }
}

/**
 * Handle a test print from the backend
 */
export async function handleTestPrint(data: any): Promise<void> {
  try {
    log('info', 'Printing test page...');

    const escposData = formatTestPrint(data);
    await printRaw(escposData);

    log('info', '✅ Test print successful');
    sendPrintCompleted();
  } catch (err: any) {
    log('error', `❌ Test print failed: ${err.message}`);
    sendPrintError(err.message);
  }
}
