; ============================================================================
; Vigie Inventory - Installateur
; ----------------------------------------------------------------------------
; Produit autonome (aucune dépendance à Billets/Parc) - bundle Node.js mais
; PAS PostgreSQL : nécessite qu'une instance PostgreSQL soit déjà présente
; sur ce poste (via Vigie Billets, ou une autre app Vigie déjà installée).
; Voir setup-app-inventory.ps1 pour le détail (aucun mot de passe codé en
; dur - toujours lu depuis une installation existante ou fourni par
; PGPASSWORD_EXISTANT).
;
; AppId identique à l'installation existante (retrouvé dans le registre de
; ce poste) pour que les mises à jour restent détectées comme telles.
; ============================================================================

#define MyAppName "Vigie Inventory"
#define MyAppVersion "2.3"
#define MyAppPublisher "C.T Informatique"
#define MyAppURL "http://localhost:3502"

[Setup]
AppId={{0D7D9E1A-6881-4F82-B6C5-04A4957B7C71}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=Vigie-Inventory-Installateur
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
Source: "payload-inventory\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "http://localhost:3502"
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "certutil.exe"; Parameters: "-addstore Root ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "certutil.exe"; Parameters: "-addstore TrustedPublisher ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\_setup\setup-app-inventory.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "Configuration de Node.js et du service - cela peut prendre quelques minutes..."; \
  Flags: runhidden waituntilterminated
Filename: "http://localhost:3502"; Description: "Ouvrir {#MyAppName} maintenant"; Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "{app}\_setup\nssm.exe"; Parameters: "stop VigieInventory"; Flags: runhidden; RunOnceId: "StopSvc"
Filename: "{app}\_setup\nssm.exe"; Parameters: "remove VigieInventory confirm"; Flags: runhidden; RunOnceId: "RemoveSvc"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*tray.ps1*' -and $_.CommandLine -like '*Vigie Inventory*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"""; Flags: runhidden; RunOnceId: "KillTray"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Remove-NetFirewallRule -DisplayName 'Vigie Inventory (port 3502)' -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
Type: files; Name: "{commondesktop}\Vigie Inventory.lnk"
Type: files; Name: "{commonstartup}\Vigie Inventory (icone).lnk"

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{0D7D9E1A-6881-4F82-B6C5-04A4957B7C71}_is1';

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

procedure StopRunningApp(const InstallDir: String);
var
  NssmExe: String;
  ResultCode: Integer;
begin
  NssmExe := InstallDir + '\_setup\nssm.exe';
  if FileExists(NssmExe) then
    Exec(NssmExe, 'stop VigieInventory', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  else
    Exec('net.exe', 'stop VigieInventory', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Exec('powershell.exe',
    '-NoProfile -WindowStyle Hidden -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*tray.ps1*'' -and $_.CommandLine -like ''*Vigie Inventory*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeSetup(): Boolean;
var
  InstalledVer, UninstallStr, Msg: String;
  InstallDir: String;
begin
  Result := True;
  InstalledVer := GetInstalledVersion();
  if InstalledVer <> '' then
  begin
    UninstallStr := GetUninstallString();
    if UninstallStr <> '' then
    begin
      InstallDir := RemoveBackslashUnlessRoot(ExtractFilePath(RemoveQuotes(UninstallStr)));
      StopRunningApp(InstallDir);
    end;
    if not WizardSilent() then
    begin
      Msg := '{#MyAppName} version ' + InstalledVer + ' est déjà installé. Cette installation va le mettre à jour vers la version {#MyAppVersion}.';
      MsgBox(Msg, mbInformation, MB_OK);
    end;
  end;
end;
