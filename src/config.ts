/**
 * Configuration Manager
 * Stores connection token and settings securely using conf (encrypted JSON file)
 */

import Conf from 'conf';

interface RelayConfig {
  connectionToken: string | null;
  stationId: string | null;
  companyId: string | null;
  locationId: string | null;
  serverUrl: string;
  printerType: 'USB' | 'NETWORK' | null;
  printerAddress: string | null; // IP:port for network printers
  printerName: string | null;
}

const store = new Conf<RelayConfig>({
  projectName: 'ticketasy-print-relay',
  defaults: {
    connectionToken: null,
    stationId: null,
    companyId: null,
    locationId: null,
    serverUrl: 'wss://api.ticketasy.com/ws/print',
    printerType: null,
    printerAddress: null,
    printerName: null,
  },
  encryptionKey: 'ticketasy-relay-v1', // Basic encryption for local storage
});

export function getConfig(): RelayConfig {
  return {
    connectionToken: store.get('connectionToken'),
    stationId: store.get('stationId'),
    companyId: store.get('companyId'),
    locationId: store.get('locationId'),
    serverUrl: store.get('serverUrl'),
    printerType: store.get('printerType'),
    printerAddress: store.get('printerAddress'),
    printerName: store.get('printerName'),
  };
}

export function saveActivation(data: {
  connectionToken: string;
  stationId: string;
  companyId: string;
  locationId: string;
}): void {
  store.set('connectionToken', data.connectionToken);
  store.set('stationId', data.stationId);
  store.set('companyId', data.companyId);
  store.set('locationId', data.locationId);
}

export function saveServerUrl(url: string): void {
  store.set('serverUrl', url);
}

export function savePrinterConfig(config: {
  printerType: 'USB' | 'NETWORK';
  printerAddress?: string;
  printerName?: string;
}): void {
  store.set('printerType', config.printerType);
  store.set('printerAddress', config.printerAddress || null);
  store.set('printerName', config.printerName || null);
}

export function clearConfig(): void {
  store.clear();
}

export function isActivated(): boolean {
  return !!store.get('connectionToken');
}
