; ============================================================================
; Vigie Simulation — Installateur
; ----------------------------------------------------------------------------
; Contrairement à Vigie Billets/Parc/Inventory, cette application n'a PAS
; besoin de PostgreSQL — les 100 scénarios sont un simple fichier de données
; chargé au démarrage. Un seul installateur sert donc à la fois pour la
; première installation et les mises à jour (Node.js est petit et détecté/
; sauté automatiquement s'il est déjà présent — inutile de séparer en deux
; installateurs comme pour les applications avec PostgreSQL).
; ============================================================================

#define MyAppName "Vigie Simulation"
#define MyAppVersion "1.9"
#define MyAppPublisher "C.T Informatique"

[Setup]
AppId={{865CEAC2-BA41-4C5D-86EF-EA4E0F515516}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=http://localhost:3503
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=Vigie-Simulation-Installateur
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
Source: "payload-simulation\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "http://localhost:3503"; IconFilename: "{app}\public\brand\vigie-simulation.ico"
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "certutil.exe"; Parameters: "-addstore Root ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "certutil.exe"; Parameters: "-addstore TrustedPublisher ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\_setup\setup-app-simulation.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "Configuration de Node.js et du service..."; \
  Flags: runhidden waituntilterminated
Filename: "http://localhost:3503"; Description: "Ouvrir {#MyAppName} maintenant"; Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "{app}\_setup\nssm.exe"; Parameters: "stop VigieSimulation"; Flags: runhidden; RunOnceId: "StopSvc"
Filename: "{app}\_setup\nssm.exe"; Parameters: "remove VigieSimulation confirm"; Flags: runhidden; RunOnceId: "RemoveSvc"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*tray-simulation.ps1*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"""; Flags: runhidden; RunOnceId: "KillTray"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Remove-NetFirewallRule -DisplayName 'Vigie Simulation (port 3503)' -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
Type: files; Name: "{commondesktop}\Vigie Simulation.lnk"
Type: files; Name: "{commonstartup}\Vigie Simulation (icône).lnk"
Type: filesandordirs; Name: "{commonprograms}\Vigie Simulation"

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{865CEAC2-BA41-4C5D-86EF-EA4E0F515516}_is1';

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
    Exec(NssmExe, 'stop VigieSimulation', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  else
    Exec('net.exe', 'stop VigieSimulation', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Tue l'icône système (nom de script distinct des autres apps — tray-simulation.ps1 —
  // pour ne jamais tuer par erreur l'icône de Billets/Parc/Inventory par ce même motif).
  Exec('powershell.exe',
    '-NoProfile -WindowStyle Hidden -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*tray-simulation.ps1*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeSetup(): Boolean;
var
  InstalledVer, UninstallStr, Msg: String;
  ResultCode: Integer;
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
    Msg := '{#MyAppName} version ' + InstalledVer + ' est déjà installé. Cette installation va le mettre à jour vers la version {#MyAppVersion}.';
    MsgBox(Msg, mbInformation, MB_OK);
  end;
end;
