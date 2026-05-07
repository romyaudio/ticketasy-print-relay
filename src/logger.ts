/**
 * Simple Logger
 * Logs to console with timestamps
 */

type LogLevel = 'info' | 'warn' | 'error' | 'debug';

const COLORS: Record<LogLevel, string> = {
  info: '\x1b[36m',   // Cyan
  warn: '\x1b[33m',   // Yellow
  error: '\x1b[31m',  // Red
  debug: '\x1b[90m',  // Gray
};
const RESET = '\x1b[0m';

export function log(level: LogLevel, message: string): void {
  const timestamp = new Date().toLocaleTimeString('es-ES');
  const color = COLORS[level];
  const prefix = `${color}[${timestamp}] [${level.toUpperCase()}]${RESET}`;
  console.log(`${prefix} ${message}`);
}
