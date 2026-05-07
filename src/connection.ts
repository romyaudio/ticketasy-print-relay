/**
 * WebSocket Connection Manager
 * Handles connection to the Ticketasy backend with auto-reconnection
 */

import WebSocket from 'ws';
import { getConfig, saveActivation, isActivated } from './config.js';
import { handlePrintJob, handleTestPrint } from './printer.js';
import { log } from './logger.js';

let ws: WebSocket | null = null;
let reconnectAttempts = 0;
let heartbeatInterval: NodeJS.Timeout | null = null;
let reconnectTimeout: NodeJS.Timeout | null = null;
let isShuttingDown = false;

const MAX_RECONNECT_DELAY = 30000; // 30 seconds max
const HEARTBEAT_INTERVAL = 30000; // 30 seconds
const INITIAL_RECONNECT_DELAY = 1000; // 1 second

/**
 * Connect to the backend WebSocket
 */
export function connect(): void {
  const config = getConfig();

  if (!config.connectionToken) {
    log('error', 'No connection token. Run activation first.');
    return;
  }

  const url = `${config.serverUrl}?token=${config.connectionToken}`;
  log('info', `Connecting to ${config.serverUrl}...`);

  ws = new WebSocket(url);

  ws.on('open', () => {
    log('info', '✅ Connected to Ticketasy backend');
    reconnectAttempts = 0;
    startHeartbeat();

    // Send printer info
    sendPrinterStatus();
  });

  ws.on('message', (data) => {
    try {
      const message = JSON.parse(data.toString());
      handleMessage(message);
    } catch (err) {
      log('error', `Failed to parse message: ${err}`);
    }
  });

  ws.on('close', (code, reason) => {
    log('warn', `Disconnected (code: ${code}, reason: ${reason.toString()})`);
    stopHeartbeat();
    ws = null;

    if (code === 4003) {
      log('error', 'Token invalid or revoked. Please re-activate.');
      return;
    }

    if (code === 4001) {
      log('warn', 'Replaced by another connection. Stopping.');
      return;
    }

    if (!isShuttingDown) {
      scheduleReconnect();
    }
  });

  ws.on('error', (err) => {
    log('error', `WebSocket error: ${err.message}`);
  });
}

/**
 * Activate with a setup code (first-time connection)
 */
export function activateWithCode(setupCode: string, serverUrl?: string): Promise<boolean> {
  return new Promise((resolve) => {
    const config = getConfig();
    const url = serverUrl || config.serverUrl;

    log('info', `Activating with code ${setupCode} at ${url}...`);

    const activationWs = new WebSocket(url);

    activationWs.on('open', () => {
      activationWs.send(JSON.stringify({
        type: 'activate',
        setupCode,
      }));
    });

    activationWs.on('message', (data) => {
      try {
        const message = JSON.parse(data.toString());

        if (message.type === 'activated') {
          log('info', '✅ Activation successful!');
          saveActivation({
            connectionToken: message.connectionToken,
            stationId: message.stationId,
            companyId: message.companyId,
            locationId: message.locationId,
          });
          activationWs.close();
          resolve(true);
        } else if (message.type === 'error') {
          log('error', `Activation failed: ${message.message}`);
          activationWs.close();
          resolve(false);
        }
      } catch (err) {
        log('error', `Activation parse error: ${err}`);
        activationWs.close();
        resolve(false);
      }
    });

    activationWs.on('error', (err) => {
      log('error', `Activation connection error: ${err.message}`);
      resolve(false);
    });

    // Timeout after 15 seconds
    setTimeout(() => {
      if (activationWs.readyState === WebSocket.OPEN) {
        activationWs.close();
      }
      resolve(false);
    }, 15000);
  });
}

/**
 * Handle incoming messages from the backend
 */
function handleMessage(message: any): void {
  switch (message.type) {
    case 'connected':
      log('info', `Registered as station ${message.stationId} for company ${message.companyId}`);
      break;

    case 'heartbeat_ack':
      // Server acknowledged our heartbeat
      break;

    case 'print:receipt':
      log('info', '🖨️ Print job received');
      handlePrintJob(message.data, message.format);
      break;

    case 'print:test':
      log('info', '🖨️ Test print received');
      handleTestPrint(message.data);
      break;

    default:
      log('warn', `Unknown message type: ${message.type}`);
  }
}

/**
 * Send heartbeat to keep connection alive
 */
function startHeartbeat(): void {
  stopHeartbeat();
  heartbeatInterval = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'heartbeat' }));
    }
  }, HEARTBEAT_INTERVAL);
}

function stopHeartbeat(): void {
  if (heartbeatInterval) {
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
  }
}

/**
 * Send printer status to backend
 */
function sendPrinterStatus(): void {
  const config = getConfig();
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'printer:status',
      printer: {
        name: config.printerName,
        type: config.printerType,
        address: config.printerAddress,
      },
    }));
  }
}

/**
 * Send print completion confirmation
 */
export function sendPrintCompleted(): void {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'print:completed' }));
  }
}

/**
 * Send print error notification
 */
export function sendPrintError(error: string): void {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'print:error', error }));
  }
}

/**
 * Schedule reconnection with exponential backoff
 */
function scheduleReconnect(): void {
  reconnectAttempts++;
  const delay = Math.min(INITIAL_RECONNECT_DELAY * Math.pow(2, reconnectAttempts - 1), MAX_RECONNECT_DELAY);
  log('info', `Reconnecting in ${delay / 1000}s (attempt ${reconnectAttempts})...`);

  reconnectTimeout = setTimeout(() => {
    connect();
  }, delay);
}

/**
 * Disconnect and cleanup
 */
export function disconnect(): void {
  isShuttingDown = true;
  stopHeartbeat();
  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout);
    reconnectTimeout = null;
  }
  if (ws) {
    ws.close(1000, 'Shutting down');
    ws = null;
  }
}

/**
 * Check if currently connected
 */
export function isConnected(): boolean {
  return ws !== null && ws.readyState === WebSocket.OPEN;
}
