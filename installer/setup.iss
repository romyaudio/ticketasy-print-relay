[Setup]
AppName=Ticket Ventas Print
AppVersion=1.0.1
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
Name: "portuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:Options}"

[CustomMessages]
spanish.AutoStart=Iniciar automáticamente con Windows
spanish.Options=Opciones:
english.AutoStart=Start automatically with Windows
english.Options=Options:
portuguese.AutoStart=Iniciar automaticamente com o Windows
portuguese.Options=Opções:

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Ticket Ventas Print"; Filename: "{app}\ticketventas_print.exe"
Name: "{group}\{cm:UninstallProgram,Ticket Ventas Print}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Ticket Ventas Print"; Filename: "{app}\ticketventas_print.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ticketventas_print.exe"; Description: "{cm:LaunchProgram,Ticket Ventas Print}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "TicketVentasPrint"; ValueData: """{app}\ticketventas_print.exe"""; Flags: uninsdeletevalue; Tasks: startup
