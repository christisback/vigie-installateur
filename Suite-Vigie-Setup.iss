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
;
; La désinstallation propose de tout désinstaller en cascade (Billets/Parc/
; Inventory/Simulation) — jamais les bases de données, seulement les
; programmes eux-mêmes. Voir CurUninstallStepChanged dans [Code].
; ============================================================================

#define MyAppName "Suite Vigie"
#define MyAppVersion "1.4"
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

// ── Désinstallation en cascade ──────────────────────────────────────────
// Suite Vigie n'est qu'une icône — mais pour l'utilisateur, "désinstaller
// Suite Vigie" doit pouvoir vouloir dire "tout enlever d'un coup". On
// propose donc de désinstaller aussi Billets/Parc/Inventory/Simulation
// (ceux réellement présents sur ce poste), sans jamais toucher à leurs
// bases de données — chaque désinstalleur individuel ne retire que son
// service Windows, ses fichiers et son icône, jamais les données PostgreSQL.
const
  AppId_Billets    = '{8F3C1A2B-6D4E-4A7F-9B12-3E5C7D9A1F00}';
  AppId_Parc       = '{A36745F6-2B1B-48B0-9A86-54BA0911A6DA}';
  AppId_Inventory  = '{0D7D9E1A-6881-4F82-B6C5-04A4957B7C71}';
  AppId_Simulation = '{865CEAC2-BA41-4C5D-86EF-EA4E0F515516}';

function GetAppUninstallString(AppId: String): String;
var
  s: String;
begin
  if not RegQueryStringValue(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + AppId + '_is1', 'UninstallString', s) then
    s := '';
  Result := s;
end;

procedure RunAppUninstaller(AppId: String);
var
  UninstStr, Exe: String;
  ResultCode: Integer;
begin
  UninstStr := GetAppUninstallString(AppId);
  if UninstStr <> '' then
  begin
    Exe := RemoveQuotes(UninstStr);
    if FileExists(Exe) then
      Exec(Exe, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

function AnyOtherAppInstalled(): Boolean;
begin
  Result :=
    (GetAppUninstallString(AppId_Billets) <> '') or
    (GetAppUninstallString(AppId_Parc) <> '') or
    (GetAppUninstallString(AppId_Inventory) <> '') or
    (GetAppUninstallString(AppId_Simulation) <> '');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Response: Integer;
  DoCascade: Boolean;
begin
  if (CurUninstallStep = usUninstall) and AnyOtherAppInstalled() then
  begin
    if UninstallSilent() then
      DoCascade := True
    else
    begin
      Response := MsgBox(
        'Désinstaller aussi Vigie Billets, Vigie Parc, Vigie Inventory et Vigie Simulation (ceux installés sur ce poste) ?' + #13#10 + #13#10 +
        'Oui : tous les programmes Vigie seront désinstallés. Leurs bases de données ne sont jamais touchées.' + #13#10 +
        'Non : seule l''icône Suite Vigie sera retirée ; les programmes resteront installés.',
        mbConfirmation, MB_YESNO);
      DoCascade := (Response = IDYES);
    end;
    if DoCascade then
    begin
      RunAppUninstaller(AppId_Parc);
      RunAppUninstaller(AppId_Inventory);
      RunAppUninstaller(AppId_Simulation);
      RunAppUninstaller(AppId_Billets);
    end;
  end;
end;
