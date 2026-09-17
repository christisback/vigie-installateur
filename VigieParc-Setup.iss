; ============================================================================
; Vigie Parc — Installateur
; ----------------------------------------------------------------------------
; Ne réinstalle ni Node.js ni PostgreSQL — nécessite que Vigie Billets soit
; déjà installé sur ce poste (il en réutilise le Node.js, le PostgreSQL et
; la base de données tickets_db). Voir setup-app-parc.ps1.
;
; AppId identique à l'installation existante (retrouvé dans le registre de
; ce poste) pour que les mises à jour restent détectées comme telles.
; ============================================================================

#define MyAppName "Vigie Parc"
#define MyAppVersion "1.7"
#define MyAppPublisher "C.T Informatique"
#define MyAppURL "http://localhost:3501"

[Setup]
AppId={{A36745F6-2B1B-48B0-9A86-54BA0911A6DA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=Vigie-Parc-Installateur
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
Source: "payload-parc\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "http://localhost:3501"
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "certutil.exe"; Parameters: "-addstore Root ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "certutil.exe"; Parameters: "-addstore TrustedPublisher ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\_setup\setup-app-parc.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "Configuration du service..."; \
  Flags: runhidden waituntilterminated
Filename: "http://localhost:3501"; Description: "Ouvrir {#MyAppName} maintenant"; Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "{app}\_setup\nssm.exe"; Parameters: "stop VigieParc"; Flags: runhidden; RunOnceId: "StopSvc"
Filename: "{app}\_setup\nssm.exe"; Parameters: "remove VigieParc confirm"; Flags: runhidden; RunOnceId: "RemoveSvc"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*tray.ps1*' -and $_.CommandLine -like '*Vigie Parc*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"""; Flags: runhidden; RunOnceId: "KillTray"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Remove-NetFirewallRule -DisplayName 'Vigie Parc (port 3501)' -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
Type: files; Name: "{commondesktop}\Vigie Parc.lnk"
Type: files; Name: "{commonstartup}\Vigie Parc (icone).lnk"

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{A36745F6-2B1B-48B0-9A86-54BA0911A6DA}_is1';

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

// Arrête le service et l'icône système d'une installation existante AVANT que
// Inno ne copie les nouveaux fichiers — sinon node.exe/tray.ps1 gardent des
// fichiers ouverts dans {app} et la copie échoue avec une erreur d'accès refusé.
procedure StopRunningApp(const InstallDir: String);
var
  NssmExe: String;
  ResultCode: Integer;
begin
  NssmExe := InstallDir + '\_setup\nssm.exe';
  if FileExists(NssmExe) then
    Exec(NssmExe, 'stop VigieParc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  else
    Exec('net.exe', 'stop VigieParc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Exec('powershell.exe',
    '-NoProfile -WindowStyle Hidden -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*tray.ps1*'' -and $_.CommandLine -like ''*Vigie Parc*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
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
