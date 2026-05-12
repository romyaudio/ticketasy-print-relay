[Setup]
AppName=Ticket Ventas Print
AppVersion=1.0.0
AppPublisher=Ticket Ventas
AppPublisherURL=https://ticketventas.com
DefaultDirName={autopf}\Ticket Ventas Print
DefaultGroupName=Ticket Ventas Print
OutputDir=..\release
OutputBaseFilename=TicketVentasPrint-Setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear acceso directo en el escritorio"; GroupDescription: "Accesos directos:"
Name: "startup"; Description: "Iniciar automáticamente con Windows"; GroupDescription: "Opciones:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Ticket Ventas Print"; Filename: "{app}\ticketventas_print.exe"
Name: "{group}\Desinstalar Ticket Ventas Print"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Ticket Ventas Print"; Filename: "{app}\ticketventas_print.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ticketventas_print.exe"; Description: "Abrir Ticket Ventas Print"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "TicketVentasPrint"; ValueData: """{app}\ticketventas_print.exe"""; Flags: uninsdeletevalue; Tasks: startup
