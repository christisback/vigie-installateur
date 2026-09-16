#define MyAppName "Vigie Billets"
#define MyAppVersion "7.49"
#define MyAppPublisher "C.T Informatique"
#define MyAppURL "http://localhost:3500"

[Setup]
AppId={{8F3C1A2B-6D4E-4A7F-9B12-3E5C7D9A1F00}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\output
OutputBaseFilename=Vigie-Billets-Installateur
Compression=none
SolidCompression=no
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableWelcomePage=no
DisableDirPage=no

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "payload\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "http://localhost:3500"
Name: "{group}\Désinstaller {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "certutil.exe"; Parameters: "-addstore Root ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "certutil.exe"; Parameters: "-addstore TrustedPublisher ""{app}\_setup\ct-informatique.cer"""; StatusMsg: "Installation du certificat de l'éditeur..."; Flags: runhidden
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\_setup\setup-app.ps1"" -InstallDir ""{app}"""; \
  StatusMsg: "Configuration de Node.js, PostgreSQL et du service — cela peut prendre plusieurs minutes..."; \
  Flags: runhidden waituntilterminated
Filename: "http://localhost:3500"; Description: "Ouvrir {#MyAppName} maintenant"; Flags: postinstall shellexec skipifsilent nowait

[UninstallRun]
Filename: "{app}\_setup\nssm.exe"; Parameters: "stop VigieBillets"; Flags: runhidden; RunOnceId: "StopSvc"
Filename: "{app}\_setup\nssm.exe"; Parameters: "remove VigieBillets confirm"; Flags: runhidden; RunOnceId: "RemoveSvc"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*tray.ps1*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"""; Flags: runhidden; RunOnceId: "KillTray"
Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -Command ""Remove-NetFirewallRule -DisplayName 'Vigie Billets (port 3500)' -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"

[UninstallDelete]
Type: files; Name: "{commonstartup}\Vigie Billets (icône).lnk"

[Code]
const
  UninstallRegKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3C1A2B-6D4E-4A7F-9B12-3E5C7D9A1F00}_is1';

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

function ShowChoiceForm(const Msg, YesCaption, NoCaption: String): Integer;
var
  Frm: TSetupForm;
  Lbl: TNewStaticText;
  BtnYes, BtnNo, BtnCancel: TNewButton;
begin
  Frm := CreateCustomForm(ScaleX(440), ScaleY(150), False, True);
  try
    Frm.Caption := '{#MyAppName}';
    Frm.Position := poScreenCenter;

    Lbl := TNewStaticText.Create(Frm);
    Lbl.Parent := Frm;
    Lbl.Left := ScaleX(16);
    Lbl.Top := ScaleY(16);
    Lbl.Width := Frm.ClientWidth - ScaleX(32);
    Lbl.AutoSize := False;
    Lbl.WordWrap := True;
    Lbl.Height := ScaleY(70);
    Lbl.Caption := Msg;

    BtnCancel := TNewButton.Create(Frm);
    BtnCancel.Parent := Frm;
    BtnCancel.Width := ScaleX(100);
    BtnCancel.Height := ScaleY(23);
    BtnCancel.Left := Frm.ClientWidth - BtnCancel.Width - ScaleX(16);
    BtnCancel.Top := Frm.ClientHeight - BtnCancel.Height - ScaleY(16);
    BtnCancel.Caption := 'Annuler';
    BtnCancel.ModalResult := mrCancel;
    BtnCancel.Cancel := True;

    BtnNo := TNewButton.Create(Frm);
    BtnNo.Parent := Frm;
    BtnNo.Width := ScaleX(130);
    BtnNo.Height := ScaleY(23);
    BtnNo.Left := BtnCancel.Left - BtnNo.Width - ScaleX(10);
    BtnNo.Top := BtnCancel.Top;
    BtnNo.Caption := NoCaption;
    BtnNo.ModalResult := mrNo;

    BtnYes := TNewButton.Create(Frm);
    BtnYes.Parent := Frm;
    BtnYes.Width := ScaleX(130);
    BtnYes.Height := ScaleY(23);
    BtnYes.Left := BtnNo.Left - BtnYes.Width - ScaleX(10);
    BtnYes.Top := BtnCancel.Top;
    BtnYes.Caption := YesCaption;
    BtnYes.ModalResult := mrYes;
    BtnYes.Default := True;

    Result := Frm.ShowModal();
  finally
    Frm.Free();
  end;
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
    Exec(NssmExe, 'stop VigieBillets', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
  else
    Exec('net.exe', 'stop VigieBillets', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // Tue l'icône système en cherchant le processus par son contenu réel (le fichier
  // tray.pid peut être périmé si l'icône a été relancée manuellement entre-temps —
  // chercher par ligne de commande évite ce problème peu importe le PID enregistré).
  Exec('powershell.exe',
    '-NoProfile -WindowStyle Hidden -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like ''*tray.ps1*'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeSetup(): Boolean;
var
  InstalledVer, UninstallStr, Msg, ActionLabel, InstallDir: String;
  Choice, ResultCode: Integer;
begin
  Result := True;
  InstalledVer := GetInstalledVersion();
  if InstalledVer <> '' then
  begin
    if InstalledVer = '{#MyAppVersion}' then
    begin
      Msg := '{#MyAppName} version ' + InstalledVer + ' est déjà installé (même version).';
      ActionLabel := 'Réinstaller';
    end
    else
    begin
      Msg := '{#MyAppName} version ' + InstalledVer + ' est installé. Cet installateur contient la version {#MyAppVersion}.';
      ActionLabel := 'Mettre à jour';
    end;

    Choice := ShowChoiceForm(Msg, ActionLabel, 'Désinstaller');
    UninstallStr := GetUninstallString();
    if Choice = mrNo then
    begin
      if UninstallStr <> '' then
      begin
        UninstallStr := RemoveQuotes(UninstallStr);
        Exec(UninstallStr, '', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
      end;
      Result := False;
    end
    else if Choice = mrCancel then
      Result := False
    else if UninstallStr <> '' then
    begin
      InstallDir := RemoveBackslashUnlessRoot(ExtractFilePath(RemoveQuotes(UninstallStr)));
      StopRunningApp(InstallDir);
    end;
  end;
end;
