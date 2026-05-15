[Setup]
AppName=Ticket Ventas Print
AppVersion=1.0.4
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
CloseApplications=force
CloseApplicationsFilter=ticketventas_print.exe

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "portuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:Options}"
Name: "clearconfig"; Description: "{cm:ClearConfig}"; GroupDescription: "{cm:Options}"; Flags: unchecked

[CustomMessages]
spanish.AutoStart=Iniciar automáticamente con Windows
spanish.Options=Opciones:
spanish.ClearConfig=Borrar configuración anterior (reactivar agente)
english.AutoStart=Start automatically with Windows
english.Options=Options:
english.ClearConfig=Clear previous configuration (reactivate agent)
portuguese.AutoStart=Iniciar automaticamente com o Windows
portuguese.Options=Opções:
portuguese.ClearConfig=Limpar configuração anterior (reativar agente)

[InstallDelete]
; Clean old files to ensure fresh install
Type: filesandordirs; Name: "{app}\data"

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

[Code]
procedure KillRunningAgent;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM ticketventas_print.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(500);
end;

procedure ClearAgentConfig;
var
  ConfigDir: String;
  LockFile: String;
begin
  ConfigDir := ExpandConstant('{userappdata}\com.ticketventas\ticketventas_print');
  if DirExists(ConfigDir) then
    DelTree(ConfigDir, True, True, True);
  LockFile := ExpandConstant('{tmp}\..\ticketventas_print.lock');
  if FileExists(LockFile) then
    DeleteFile(LockFile);
end;

function InitializeSetup(): Boolean;
begin
  KillRunningAgent;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    if WizardIsTaskSelected('clearconfig') then
      ClearAgentConfig;
  end;
end;
