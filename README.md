# Ticketasy Print Relay Agent

Agente de impresión silenciosa para Ticketasy. Se conecta al backend vía WebSocket y envía recibos directamente a la impresora térmica sin intervención del usuario.

## Instalación rápida

### Windows

1. Descarga `TicketasyPrint-Setup.exe` desde el panel
2. Instala (Next → Next → Install)
3. Ejecuta y pega el código de conexión

### Mac

1. Descarga `TicketasyPrint.dmg`
2. Arrastra a Aplicaciones
3. Ejecuta y pega el código de conexión

### Linux / Raspberry Pi

```bash
curl -sL https://github.com/romyaudio/ticketasy-print-relay/releases/latest/download/ticketasy-print-relay-linux -o ticketasy-print-relay
chmod +x ticketasy-print-relay
./ticketasy-print-relay --activate TU-CODIGO-AQUI
```

## Uso desde línea de comandos

### Primera vez (activación)

```bash
# 1. Configura el servidor (solo si no es producción)
ticketasy-print-relay --server wss://tu-servidor.com/ws/print

# 2. Activa con el código del panel
ticketasy-print-relay --activate ABC-XY7-9KM

# 3. Configura la impresora
ticketasy-print-relay --printer network 192.168.1.100:9100
# o para USB:
ticketasy-print-relay --printer usb
```

### Ejecución normal

```bash
ticketasy-print-relay
```

### Otros comandos

```bash
ticketasy-print-relay --status    # Ver estado actual
ticketasy-print-relay --reset     # Borrar configuración
ticketasy-print-relay --help      # Ayuda
```

## Desarrollo

```bash
# Instalar dependencias
npm install

# Ejecutar en modo desarrollo
npm run dev

# Compilar
npm run build

# Empaquetar ejecutable
npm run package:win    # Windows
npm run package:mac    # macOS
npm run package:linux  # Linux
```

## Impresoras compatibles

### Red (TCP:9100)

- Epson TM-T20/T82/T88
- Star TSP100/TSP650
- Bixolon SRP-350
- Cualquier impresora con puerto Ethernet/WiFi y protocolo ESC/POS

### USB

- Mismas marcas en versión USB
- Impresoras genéricas 58mm/80mm con driver ESC/POS

## Arquitectura

```
Ticketasy Backend (AWS)
    ↓ WebSocket Secure (WSS)
Print Relay (este programa)
    ↓ TCP:9100 (red) o USB directo
Impresora térmica
```

El relay mantiene una conexión WebSocket persistente con el backend. Cuando se completa una venta, el backend envía los datos del recibo al relay, que los formatea en ESC/POS y los envía a la impresora.

## Seguridad

- Conexión cifrada (WSS/TLS)
- Token de autenticación único por estación
- Solo recibe datos de recibos (no accede a archivos ni ejecuta comandos)
- No expone puertos (conexión saliente únicamente)
- Token revocable desde el panel web
