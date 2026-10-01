; ============================================================================
; Vigie Centre d'Appel - Installateur
; ----------------------------------------------------------------------------
; Ne réinstalle ni Node.js ni PostgreSQL - nécessite que Vigie Billets soit
; déjà installé sur ce poste (il en réutilise le Node.js, le PostgreSQL, la
; base de données tickets_db et le secret de connexion JWT_SECRET, pour qu'un
; jeton émis par Billets soit accepté directement ici). Voir
; setup-app-centreappel.ps1.
;
; Application en bêta : premier appareillage de l'installateur, pas encore
; déployé en production.
; ============================================================================

#define MyAppName "Vigie Centre d'Appel"
#define MyAppVersion "1.0.0-beta"
#define MyAppPublisher "C.T Informatique"
#define MyAppURL "https://localhost:3505"

[Setup]
AppId={{D55719F9-10D1-490A-8AE2-A9300A641D48}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=Vigie-CentreAppel-Installateur
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
Source: "payload-centreappel\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "https://localhost:3505"
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "certutil.exe"; Parameters: "-addstore Root ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "certutil.exe"; Parameters: "-addstore TrustedPublisher ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\_setup\setup-app-centreappel.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "Configuration du service et du certificat HTTPS - cela peut prendre quelques minutes..."; \
  Flags: runhidden waituntilterminated
Filename: "https://localhost:3505"; Description: "Ouvrir {#MyAppName} maintenant"; Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "{app}\_setup\nssm.exe"; Parameters: "stop VigieCentreAppel"; Flags: runhidden; RunOnceId: "StopSvc"
Filename: "{app}\_setup\nssm.exe"; Parameters: "remove VigieCentreAppel confirm"; Flags: runhidden; RunOnceId: "RemoveSvc"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Remove-NetFirewallRule -DisplayName 'Vigie Centre d''Appel (port 3504)' -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Remove-NetFirewallRule -DisplayName 'Vigie Centre d''Appel HTTPS (port 3505)' -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveFirewallRuleHttps"

[UninstallDelete]
Type: files; Name: "{commondesktop}\Vigie Centre d'Appel.lnk"

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{D55719F9-10D1-490A-8AE2-A9300A641D48}_is1';

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

// Arrête le service d'une installation existante AVANT qu'Inno ne copie les nouveaux fichiers -
// sinon node.exe garde des fichiers ouverts dans {app} et la copie échoue (accès refusé).
procedure StopRunningApp(const InstallDir: String);
var
  NssmExe: String;
  ResultCode: Integer;
begin
  NssmExe := InstallDir + '\_setup\nssm.exe';
  if FileExists(NssmExe) then
    Exec(NssmExe, 'stop VigieCentreAppel', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  else
    Exec('net.exe', 'stop VigieCentreAppel', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
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
      Msg := 'Vigie Centre d''Appel version ' + InstalledVer + ' est déjà installé. Cette installation va le mettre à jour vers la version {#MyAppVersion}.';
      MsgBox(Msg, mbInformation, MB_OK);
    end;
  end;
end;
