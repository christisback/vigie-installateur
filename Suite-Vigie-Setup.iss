; ============================================================================
; Suite Vigie — Icône unifiée barre système
; ----------------------------------------------------------------------------
; Aucun serveur, aucune base de données — juste un script PowerShell (tray.ps1)
; qui affiche une icône dans la barre système avec un sous-menu par application
; Vigie réellement détectée sur ce poste (Billets/Parc/Inventory/Simulation,
; via leurs services Windows). Remplace les icônes individuelles de chaque app
; pour éviter les doublons.
;
; AppId identique à l'installation existante (retrouvé dans le registre de ce
; poste, "Suite Vigie version 1.1") pour que les mises à jour restent détectées
; comme telles plutôt que comme une toute nouvelle installation.
; ============================================================================

#define MyAppName "Suite Vigie"
#define MyAppVersion "1.3"
#define MyAppPublisher "C.T Informatique"

[Setup]
AppId={{4302CA0A-DCB2-4A07-A3A0-C4958E431F87}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=Vigie-Suite-Installateur
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableWelcomePage=no
DisableDirPage=no

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "payload-suite\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "certutil.exe"; Parameters: "-addstore Root ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "certutil.exe"; Parameters: "-addstore TrustedPublisher ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\_setup\setup-app.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "Configuration de l'icône Suite Vigie..."; \
  Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*tray.ps1*' -and $_.CommandLine -like '*Suite Vigie*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"""; Flags: runhidden; RunOnceId: "KillTray"

[UninstallDelete]
Type: files; Name: "{commonstartup}\Suite Vigie (icone).lnk"

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{4302CA0A-DCB2-4A07-A3A0-C4958E431F87}_is1';

function GetInstalledVersion(): String;
var
  v: String;
begin
  if not RegQueryStringValue(HKLM, UninstallRegKey, 'DisplayVersion', v) then v := '';
  Result := v;
end;

function GetUninstallString(): String;
var
  s: String;
begin
  if not RegQueryStringValue(HKLM, UninstallRegKey, 'UninstallString', s) then s := '';
  Result := s;
end;

procedure StopRunningApp;
var
  ResultCode: Integer;
begin
  Exec('powershell.exe',
    '-NoProfile -WindowStyle Hidden -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*tray.ps1*'' -and $_.CommandLine -like ''*Suite Vigie*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeSetup(): Boolean;
var
  InstalledVer, UninstallStr, Msg: String;
begin
  Result := True;
  InstalledVer := GetInstalledVersion();
  if InstalledVer <> '' then
  begin
    StopRunningApp;
    if not WizardSilent() then
    begin
      Msg := '{#MyAppName} version ' + InstalledVer + ' est déjà installé. Cette installation va le mettre à jour vers la version {#MyAppVersion}.';
      MsgBox(Msg, mbInformation, MB_OK);
    end;
  end;
end;
