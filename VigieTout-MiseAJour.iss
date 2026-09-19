; ============================================================================
; Vigie Tout - Mise à jour groupée
; ----------------------------------------------------------------------------
; Met à jour Vigie Billets, Vigie Parc, Vigie Inventory et Vigie Simulation en
; une seule exécution. Ne fait JAMAIS de première installation - un programme
; non détecté sur ce poste est simplement ignoré (voir InitializeSetup).
;
; Détection par présence du fichier server.js dans le dossier d'installation
; standard de chaque produit (plutôt que par AppId de registre) - évite toute
; dépendance à un identifiant qu'on ne connaît pas forcément pour un produit
; donné, et reflète l'état réel du poste plutôt qu'une entrée de registre qui
; pourrait être désynchronisée.
;
; Équivalent à lancer Vigie-Billets-MiseAJour.exe, Vigie-Parc-Installateur.exe
; et Vigie-Inventory-MiseAJour.exe un par un - chacun garde son propre
; assistant (pas de mode silencieux, pour la même raison que le sélecteur
; combiné : leur boîte "déjà installé ?" ignorerait /VERYSILENT).
; ============================================================================

#define MyAppName "Vigie Tout - Mise à jour groupée"
#define MyAppVersion "1.0"
#define MyAppPublisher "C.T Informatique"

[Setup]
AppId={{B0F81227-DE8F-42A1-B29E-CE0D9F802023}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\_VigieToutMiseAJourTemp
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableDirPage=yes
DisableReadyPage=yes
Uninstallable=no
OutputDir=..\output
OutputBaseFilename=Vigie-Tout-MiseAJour
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "..\Vigie-Billets-MiseAJour.exe";      DestDir: "{tmp}"; Flags: dontcopy
Source: "..\Vigie-Parc-Installateur.exe";      DestDir: "{tmp}"; Flags: dontcopy
Source: "..\Vigie-Inventory-MiseAJour.exe";    DestDir: "{tmp}"; Flags: dontcopy
Source: "..\Vigie-Simulation-Installateur.exe"; DestDir: "{tmp}"; Flags: dontcopy

[Run]
Filename: "{tmp}\Vigie-Billets-MiseAJour.exe";      Parameters: "/SP-"; StatusMsg: "Mise à jour de Vigie Billets…";      Check: BilletsInstalled;    Flags: waituntilterminated
Filename: "{tmp}\Vigie-Parc-Installateur.exe";      Parameters: "/SP-"; StatusMsg: "Mise à jour de Vigie Parc…";        Check: ParcInstalled;       Flags: waituntilterminated
Filename: "{tmp}\Vigie-Inventory-MiseAJour.exe";    Parameters: "/SP-"; StatusMsg: "Mise à jour de Vigie Inventory…";   Check: InventoryInstalled;  Flags: waituntilterminated
Filename: "{tmp}\Vigie-Simulation-Installateur.exe"; Parameters: "/SP-"; StatusMsg: "Mise à jour de Vigie Simulation…"; Check: SimulationInstalled; Flags: waituntilterminated

[Code]
function AppFileExists(const Dirname, Filename: String): Boolean;
begin
  Result := FileExists(ExpandConstant('{autopf}\' + Dirname + '\' + Filename));
end;

function BilletsInstalled: Boolean;
begin
  Result := AppFileExists('Vigie Billets', 'server.js');
end;

function ParcInstalled: Boolean;
begin
  Result := AppFileExists('Vigie Parc', 'server.js');
end;

function InventoryInstalled: Boolean;
begin
  Result := AppFileExists('Vigie Inventory', 'server.js');
end;

function SimulationInstalled: Boolean;
begin
  Result := AppFileExists('Vigie Simulation', 'server.js');
end;

function InitializeSetup: Boolean;
var
  Detected, Msg: String;
  N: Integer;
begin
  Detected := '';
  N := 0;
  if BilletsInstalled then begin Detected := Detected + '   •  Vigie Billets' + #13#10; N := N + 1; end;
  if ParcInstalled then begin Detected := Detected + '   •  Vigie Parc' + #13#10; N := N + 1; end;
  if InventoryInstalled then begin Detected := Detected + '   •  Vigie Inventory' + #13#10; N := N + 1; end;
  if SimulationInstalled then begin Detected := Detected + '   •  Vigie Simulation' + #13#10; N := N + 1; end;

  if N = 0 then
  begin
    MsgBox('Aucun des programmes Vigie Billets / Vigie Parc / Vigie Inventory / Vigie Simulation n''a été détecté sur ce poste.' + #13#10#13#10 +
      'Cet outil ne fait jamais de première installation - utilisez l''installateur individuel du programme voulu ' +
      '(ou l''installateur combiné Suite Vigie) pour une première installation.',
      mbError, MB_OK);
    Result := False;
    Exit;
  end;

  Msg := 'Programmes détectés sur ce poste :' + #13#10#13#10 + Detected + #13#10 + 'Continuer la mise à jour de ces programmes ?';
  Result := (MsgBox(Msg, mbConfirmation, MB_YESNO) = IDYES);
end;

// Les fichiers "dontcopy" ne sont jamais extraits automatiquement - sans cet
// appel explicite, {tmp}\Vigie-*.exe n'existe pas quand [Run] essaie de le
// lancer, et la mise à jour échoue ("fichier introuvable").
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    if BilletsInstalled then
      ExtractTemporaryFile('Vigie-Billets-MiseAJour.exe');
    if ParcInstalled then
      ExtractTemporaryFile('Vigie-Parc-Installateur.exe');
    if InventoryInstalled then
      ExtractTemporaryFile('Vigie-Inventory-MiseAJour.exe');
    if SimulationInstalled then
      ExtractTemporaryFile('Vigie-Simulation-Installateur.exe');
  end;
end;
