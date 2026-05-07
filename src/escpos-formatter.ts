/**
 * ESC/POS Receipt Formatter
 * Converts receipt data + format config into ESC/POS byte commands
 */

// ESC/POS command constants
const ESC = 0x1B;
const GS = 0x1D;
const LF = 0x0A;

const CMD = {
  INIT: Buffer.from([ESC, 0x40]), // Initialize printer
  ALIGN_CENTER: Buffer.from([ESC, 0x61, 0x01]),
  ALIGN_LEFT: Buffer.from([ESC, 0x61, 0x00]),
  ALIGN_RIGHT: Buffer.from([ESC, 0x61, 0x02]),
  BOLD_ON: Buffer.from([ESC, 0x45, 0x01]),
  BOLD_OFF: Buffer.from([ESC, 0x45, 0x00]),
  DOUBLE_HEIGHT_ON: Buffer.from([ESC, 0x21, 0x10]),
  DOUBLE_WIDTH_ON: Buffer.from([ESC, 0x21, 0x20]),
  DOUBLE_ON: Buffer.from([ESC, 0x21, 0x30]), // Double width + height
  NORMAL_SIZE: Buffer.from([ESC, 0x21, 0x00]),
  CUT_PAPER: Buffer.from([GS, 0x56, 0x00]), // Full cut
  CUT_PARTIAL: Buffer.from([GS, 0x56, 0x01]), // Partial cut
  FEED_LINES: (n: number) => Buffer.from([ESC, 0x64, n]),
  OPEN_DRAWER: Buffer.from([ESC, 0x70, 0x00, 0x19, 0xFA]), // Pin 2, 25ms on, 250ms off
  UNDERLINE_ON: Buffer.from([ESC, 0x2D, 0x01]),
  UNDERLINE_OFF: Buffer.from([ESC, 0x2D, 0x00]),
};

interface ReceiptItem {
  name: string;
  quantity: number;
  price: number;
}

interface ReceiptData {
  orderId: string;
  companyName: string;
  companyAddress: string;
  companyPhone: string;
  locationName: string;
  createdAt: string;
  employeeName: string | null;
  items: ReceiptItem[];
  subtotal: number;
  taxAmount: number;
  discountAmount: number;
  total: number;
  paymentMethod: string;
  paidAmount: number;
  changeAmount: number;
}

interface ReceiptFormat {
  paperWidth: '80mm' | '58mm';
  showLogo: boolean;
  showAddress: boolean;
  showPhone: boolean;
  showEmployee: boolean;
  showPaymentMethod: boolean;
  showTaxBreakdown: boolean;
  showOrderNumber: boolean;
  footerMessage: string;
  autoCut: boolean;
  openDrawer: boolean;
}

/**
 * Get line width based on paper size
 */
function getLineWidth(paperWidth: string): number {
  return paperWidth === '58mm' ? 32 : 48;
}

/**
 * Pad/truncate text to fit line width
 */
function padLine(left: string, right: string, width: number): string {
  const maxLeft = width - right.length - 1;
  const truncatedLeft = left.length > maxLeft ? left.substring(0, maxLeft) : left;
  const padding = width - truncatedLeft.length - right.length;
  return truncatedLeft + ' '.repeat(Math.max(1, padding)) + right;
}

/**
 * Create a separator line
 */
function separator(char: string, width: number): string {
  return char.repeat(width);
}

/**
 * Format currency
 */
function formatCurrency(amount: number): string {
  return `$${amount.toFixed(2)}`;
}

/**
 * Format payment method name
 */
function formatPaymentMethod(method: string): string {
  const methods: Record<string, string> = {
    CASH: 'Efectivo',
    CARD: 'Tarjeta',
    TRANSFER: 'Transferencia',
    CHECK: 'Cheque',
    OTHER: 'Otro',
  };
  return methods[method] || method;
}

/**
 * Format date/time
 */
function formatDateTime(isoString: string): { date: string; time: string } {
  const d = new Date(isoString);
  const date = d.toLocaleDateString('es-ES', { year: 'numeric', month: '2-digit', day: '2-digit' });
  const time = d.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' });
  return { date, time };
}

/**
 * Generate ESC/POS buffer for a receipt
 */
export function formatReceipt(data: ReceiptData, format: ReceiptFormat): Buffer {
  const width = getLineWidth(format.paperWidth);
  const buffers: Buffer[] = [];

  const text = (str: string) => buffers.push(Buffer.from(str + '\n', 'latin1'));
  const cmd = (buf: Buffer) => buffers.push(buf);
  const newline = () => buffers.push(Buffer.from([LF]));

  // Initialize
  cmd(CMD.INIT);

  // === HEADER ===
  cmd(CMD.ALIGN_CENTER);
  cmd(CMD.BOLD_ON);
  cmd(CMD.DOUBLE_ON);
  text(data.companyName || 'RECIBO');
  cmd(CMD.NORMAL_SIZE);
  cmd(CMD.BOLD_OFF);

  if (format.showAddress && data.companyAddress) {
    text(data.companyAddress);
  }
  if (format.showPhone && data.companyPhone) {
    text(`Tel: ${data.companyPhone}`);
  }
  if (data.locationName) {
    text(data.locationName);
  }

  text(separator('=', width));

  // === DATE & EMPLOYEE ===
  cmd(CMD.ALIGN_LEFT);
  const { date, time } = formatDateTime(data.createdAt);
  text(`Fecha: ${date}  Hora: ${time}`);

  if (format.showEmployee && data.employeeName) {
    text(`Atendido por: ${data.employeeName}`);
  }

  if (format.showOrderNumber) {
    text(`Orden: #${data.orderId.slice(-8)}`);
  }

  text(separator('-', width));

  // === ITEMS ===
  for (const item of data.items) {
    const itemTotal = item.price * item.quantity;
    const qtyStr = item.quantity > 1 ? `x${item.quantity}` : '';
    const priceStr = formatCurrency(itemTotal);
    const nameWithQty = qtyStr ? `${item.name} ${qtyStr}` : item.name;
    text(padLine(nameWithQty, priceStr, width));
  }

  newline();
  text(separator('-', width));

  // === TOTALS ===
  if (format.showTaxBreakdown) {
    text(padLine('Subtotal:', formatCurrency(data.subtotal), width));
    if (data.taxAmount > 0) {
      text(padLine('Impuestos:', formatCurrency(data.taxAmount), width));
    }
    if (data.discountAmount > 0) {
      text(padLine('Descuento:', `-${formatCurrency(data.discountAmount)}`, width));
    }
  }

  text(separator('=', width));
  cmd(CMD.BOLD_ON);
  cmd(CMD.DOUBLE_HEIGHT_ON);
  text(padLine('TOTAL:', formatCurrency(data.total), width));
  cmd(CMD.NORMAL_SIZE);
  cmd(CMD.BOLD_OFF);
  text(separator('=', width));

  // === PAYMENT ===
  if (format.showPaymentMethod) {
    text(padLine('Método:', formatPaymentMethod(data.paymentMethod), width));
    text(padLine('Pagado:', formatCurrency(data.paidAmount), width));
    if (data.changeAmount > 0) {
      text(padLine('Cambio:', formatCurrency(data.changeAmount), width));
    }
  }

  // === FOOTER ===
  newline();
  text(separator('-', width));
  cmd(CMD.ALIGN_CENTER);
  if (format.footerMessage) {
    text(format.footerMessage);
  }
  text(separator('=', width));

  // Feed and cut
  cmd(CMD.FEED_LINES(4));
  if (format.autoCut) {
    cmd(CMD.CUT_PARTIAL);
  }

  // Open cash drawer
  if (format.openDrawer) {
    cmd(CMD.OPEN_DRAWER);
  }

  return Buffer.concat(buffers);
}

/**
 * Generate ESC/POS buffer for a test print
 */
export function formatTestPrint(data: { companyName: string; message: string; timestamp: string }): Buffer {
  const width = 48;
  const buffers: Buffer[] = [];

  const text = (str: string) => buffers.push(Buffer.from(str + '\n', 'latin1'));
  const cmd = (buf: Buffer) => buffers.push(buf);

  cmd(CMD.INIT);
  cmd(CMD.ALIGN_CENTER);
  cmd(CMD.BOLD_ON);
  cmd(CMD.DOUBLE_ON);
  text('PRUEBA DE IMPRESION');
  cmd(CMD.NORMAL_SIZE);
  cmd(CMD.BOLD_OFF);

  text(separator('=', width));
  text(data.companyName);
  text('');
  text(data.message);
  text('');
  text(new Date(data.timestamp).toLocaleString('es-ES'));
  text(separator('=', width));
  text('Ticketasy Print Relay v1.0.0');

  cmd(CMD.FEED_LINES(4));
  cmd(CMD.CUT_PARTIAL);

  return Buffer.concat(buffers);
}
