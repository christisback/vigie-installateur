; ============================================================================
; Suite Vigie — Installateur combiné
; ----------------------------------------------------------------------------
; Ce n'est PAS un installateur monolithique qui réimplémente chaque produit —
; c'est un SÉLECTEUR : il embarque les installateurs individuels déjà
; existants (Vigie-Billets-Installateur.exe, Vigie-Parc-Installateur.exe,
; Vigie-Inventory-Installateur.exe, Vigie-Suite-Installateur.exe) et lance,
; dans le bon ordre, ceux que l'utilisateur a cochés. Chaque produit garde
; ainsi son propre AppId / sa propre entrée de désinstallation / son propre
; installateur de mise à jour, exactement comme s'il avait été installé
; individuellement — la mise à jour d'un produit reste compatible avec son
; MiseAJour.exe dédié après coup.
;
; Vigie Parc partage la base de données de Vigie Billets et ne peut pas
; s'installer sans lui — le cocher force donc automatiquement Vigie Billets.
;
; Les installateurs enfants gardent leur propre assistant (langue, dossier,
; détection "déjà installé" avec sa boîte de dialogue Réinstaller/Mettre à
; jour/Désinstaller) — on ne les lance PAS en /VERYSILENT, car leur logique
; d'installation existante peut afficher une boîte de dialogue personnalisée
; qui ignore le mode silencieux et bloquerait indéfiniment une exécution
; cachée. /SP- supprime seulement l'invite "Ceci va installer..." d'Inno.
; ============================================================================

#define MyAppName "Suite Vigie — Installateur combiné"
#define MyAppVersion "1.0"
#define MyAppPublisher "C.T Informatique"

[Setup]
AppId={{9C7E2F14-5A61-4C3D-8E2A-1B7F4D6C9A03}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Suite Vigie Installateur
DisableProgramGroupPage=yes
DisableWelcomePage=no
DisableDirPage=yes
DisableReadyPage=no
Uninstallable=no
OutputDir=..\output
OutputBaseFilename=Suite-Vigie-Installateur-Combine
Compression=none
SolidCompression=no
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Types]
Name: "full"; Description: "Tout installer"
Name: "custom"; Description: "Sélection personnalisée"; Flags: iscustom

[Components]
Name: "billets"; Description: "Vigie Billets — billetterie de support (port 3500)"; Types: full custom
Name: "parc"; Description: "Vigie Parc — inventaire de parc informatique (port 3501, nécessite Vigie Billets)"; Types: full custom
Name: "inventory"; Description: "Vigie Inventory — inventaire générique autonome (port 3502)"; Types: full custom
Name: "suite"; Description: "Suite Vigie — icône unifiée dans la barre système"; Types: full custom

[Files]
Source: "..\Vigie-Billets-Installateur.exe";   DestDir: "{tmp}"; Flags: dontcopy; Components: billets
Source: "..\Vigie-Parc-Installateur.exe";      DestDir: "{tmp}"; Flags: dontcopy; Components: parc
Source: "..\Vigie-Inventory-Installateur.exe"; DestDir: "{tmp}"; Flags: dontcopy; Components: inventory
Source: "..\Vigie-Suite-Installateur.exe";     DestDir: "{tmp}"; Flags: dontcopy; Components: suite

[Run]
Filename: "{tmp}\Vigie-Billets-Installateur.exe";   Parameters: "/SP-"; StatusMsg: "Installation de Vigie Billets…";   Check: WizardIsComponentSelected('billets');   Flags: waituntilterminated
Filename: "{tmp}\Vigie-Parc-Installateur.exe";      Parameters: "/SP-"; StatusMsg: "Installation de Vigie Parc…";      Check: WizardIsComponentSelected('parc');      Flags: waituntilterminated
Filename: "{tmp}\Vigie-Inventory-Installateur.exe"; Parameters: "/SP-"; StatusMsg: "Installation de Vigie Inventory…"; Check: WizardIsComponentSelected('inventory'); Flags: waituntilterminated
Filename: "{tmp}\Vigie-Suite-Installateur.exe";     Parameters: "/SP-"; StatusMsg: "Installation de Suite Vigie…";     Check: WizardIsComponentSelected('suite');     Flags: waituntilterminated

[Code]
// Indices dans [Components], dans l'ordre déclaré ci-dessus.
const
  IdxBillets   = 0;
  IdxParc      = 1;
  IdxInventory = 2;
  IdxSuite     = 3;

// Vigie Parc partage la base de données de Vigie Billets — il ne peut pas
// s'installer seul. Cocher Parc force donc Billets automatiquement.
procedure EnforceParcRequiresBillets;
begin
  if WizardForm.ComponentsList.Checked[IdxParc] and not WizardForm.ComponentsList.Checked[IdxBillets] then
  begin
    WizardForm.ComponentsList.Checked[IdxBillets] := True;
    MsgBox('Vigie Parc utilise la même base de données que Vigie Billets — Vigie Billets a été coché automatiquement.',
      mbInformation, MB_OK);
  end;
end;

procedure ComponentsListClickCheck(Sender: TObject);
begin
  EnforceParcRequiresBillets;
end;

procedure InitializeWizard;
begin
  WizardForm.ComponentsList.OnClickCheck := @ComponentsListClickCheck;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectComponents then
    EnforceParcRequiresBillets;
end;

// Les fichiers marqués "dontcopy" dans [Files] ne sont JAMAIS extraits
// automatiquement (contrairement à un [Files] normal) — sans cet appel
// explicite, {tmp}\Vigie-*.exe n'existe pas quand [Run] essaie de le
// lancer, et l'installation échoue ("fichier introuvable"). On extrait
// seulement ce qui a été coché, juste avant que [Run] ne s'exécute.
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    if WizardIsComponentSelected('billets') then
      ExtractTemporaryFile('Vigie-Billets-Installateur.exe');
    if WizardIsComponentSelected('parc') then
      ExtractTemporaryFile('Vigie-Parc-Installateur.exe');
    if WizardIsComponentSelected('inventory') then
      ExtractTemporaryFile('Vigie-Inventory-Installateur.exe');
    if WizardIsComponentSelected('suite') then
      ExtractTemporaryFile('Vigie-Suite-Installateur.exe');
  end;
end;
