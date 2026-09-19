; ============================================================================
; Suite Vigie - Installateur combiné
; ----------------------------------------------------------------------------
; Ce n'est PAS un installateur monolithique qui réimplémente chaque produit -
; c'est un SÉLECTEUR : il embarque les installateurs individuels déjà
; existants (Vigie-Billets-Installateur.exe, Vigie-Parc-Installateur.exe,
; Vigie-Inventory-Installateur.exe, Vigie-Suite-Installateur.exe) et lance,
; dans le bon ordre, ceux que l'utilisateur a cochés. Chaque produit garde
; ainsi son propre AppId / sa propre entrée de désinstallation / son propre
; installateur de mise à jour, exactement comme s'il avait été installé
; individuellement - la mise à jour d'un produit reste compatible avec son
; MiseAJour.exe dédié après coup.
;
; Vigie Parc partage la base de données de Vigie Billets et ne peut pas
; s'installer sans lui - le cocher force donc automatiquement Vigie Billets.
;
; Les installateurs enfants gardent leur propre assistant (langue, dossier,
; détection "déjà installé" avec sa boîte de dialogue Réinstaller/Mettre à
; jour/Désinstaller) - on ne les lance PAS en /VERYSILENT, car leur logique
; d'installation existante peut afficher une boîte de dialogue personnalisée
; qui ignore le mode silencieux et bloquerait indéfiniment une exécution
; cachée. /SP- supprime seulement l'invite "Ceci va installer..." d'Inno.
;
; Vigie Billets : Vigie-Billets-Installateur.exe (avec PostgreSQL intégré)
; contient un bug connu qui fait échouer l'installation silencieuse de
; PostgreSQL sur un poste qui ne l'a pas déjà. Ce combiné choisit donc
; automatiquement Vigie-Billets-MiseAJour.exe (corrigé) si PostgreSQL est
; déjà présent sur le poste, et avertit l'utilisateur sinon. Voir
; GetBilletsInstallerFile dans [Code].
; ============================================================================

#define MyAppName "Suite Vigie - Installateur combiné"
#define MyAppVersion "2.2"
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
Name: "billets"; Description: "Vigie Billets - billetterie de support (port 3500)"; Types: full custom
Name: "parc"; Description: "Vigie Parc - inventaire de parc informatique (port 3501, nécessite Vigie Billets)"; Types: full custom
Name: "inventory"; Description: "Vigie Inventory - inventaire générique autonome (port 3502)"; Types: full custom
Name: "simulation"; Description: "Vigie Simulation - scénarios de soutien informatique pour la formation (port 3503)"; Types: full custom
Name: "suite"; Description: "Suite Vigie - icône unifiée dans la barre système"; Types: full custom

[Files]
Source: "..\Vigie-Billets-Installateur.exe";     DestDir: "{tmp}"; Flags: dontcopy; Components: billets
Source: "..\Vigie-Billets-MiseAJour.exe";        DestDir: "{tmp}"; Flags: dontcopy; Components: billets
Source: "..\Vigie-Parc-Installateur.exe";        DestDir: "{tmp}"; Flags: dontcopy; Components: parc
Source: "..\Vigie-Inventory-Installateur.exe";   DestDir: "{tmp}"; Flags: dontcopy; Components: inventory
Source: "..\Vigie-Simulation-Installateur.exe";  DestDir: "{tmp}"; Flags: dontcopy; Components: simulation
Source: "..\Vigie-Suite-Installateur.exe";       DestDir: "{tmp}"; Flags: dontcopy; Components: suite

[Run]
Filename: "{tmp}\{code:GetBilletsInstallerFile}";     Parameters: "/SP-"; StatusMsg: "Installation de Vigie Billets…";     Check: WizardIsComponentSelected('billets');     Flags: waituntilterminated
Filename: "{tmp}\Vigie-Parc-Installateur.exe";        Parameters: "/SP-"; StatusMsg: "Installation de Vigie Parc…";        Check: WizardIsComponentSelected('parc');        Flags: waituntilterminated
Filename: "{tmp}\Vigie-Inventory-Installateur.exe";   Parameters: "/SP-"; StatusMsg: "Installation de Vigie Inventory…";   Check: WizardIsComponentSelected('inventory');   Flags: waituntilterminated
Filename: "{tmp}\Vigie-Simulation-Installateur.exe";  Parameters: "/SP-"; StatusMsg: "Installation de Vigie Simulation…"; Check: WizardIsComponentSelected('simulation');  Flags: waituntilterminated
Filename: "{tmp}\Vigie-Suite-Installateur.exe";       Parameters: "/SP-"; StatusMsg: "Installation de Suite Vigie…";       Check: WizardIsComponentSelected('suite');       Flags: waituntilterminated

[Code]
// Indices dans [Components], dans l'ordre déclaré ci-dessus.
const
  IdxBillets    = 0;
  IdxParc       = 1;
  IdxInventory  = 2;
  IdxSimulation = 3;
  IdxSuite      = 4;

// Vigie Parc partage la base de données de Vigie Billets - il ne peut pas
// s'installer seul. Cocher Parc force donc Billets automatiquement.
procedure EnforceParcRequiresBillets;
begin
  if WizardForm.ComponentsList.Checked[IdxParc] and not WizardForm.ComponentsList.Checked[IdxBillets] then
  begin
    WizardForm.ComponentsList.Checked[IdxBillets] := True;
    MsgBox('Vigie Parc utilise la même base de données que Vigie Billets - Vigie Billets a été coché automatiquement.',
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

// Vigie-Billets-Installateur.exe (le gros fichier avec PostgreSQL intégré)
// contient un bug connu : son installation silencieuse de PostgreSQL échoue
// sur un poste qui ne l'a pas encore ("option attendu mais contient
// Files\PostgreSQL\18" - bug de citation PowerShell). Vigie-Billets-MiseAJour.exe
// contient le correctif mais suppose PostgreSQL déjà présent. On choisit
// donc automatiquement le bon fichier selon ce qui est réellement présent
// sur CE poste, pour éviter le bug dans le cas le plus courant (PostgreSQL
// déjà installé, ce qui est le cas de la plupart des postes de ce parc).
function PostgresAlreadyPresent(): Boolean;
begin
  Result := FileExists('C:\Program Files\PostgreSQL\18\bin\psql.exe');
end;

function GetBilletsInstallerFile(Param: String): String;
begin
  if PostgresAlreadyPresent() then
    Result := 'Vigie-Billets-MiseAJour.exe'
  else
    Result := 'Vigie-Billets-Installateur.exe';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectComponents then
  begin
    EnforceParcRequiresBillets;
    if WizardIsComponentSelected('billets') and not PostgresAlreadyPresent() then
    begin
      Result := (MsgBox(
        'PostgreSQL n''est pas encore installé sur ce poste. L''installation automatique de PostgreSQL par Vigie Billets contient actuellement un bug connu qui peut faire échouer l''installation.' + #13#10 + #13#10 +
        'Il est recommandé d''installer PostgreSQL 18 manuellement d''abord (postgresql.org, mot de passe superutilisateur 123 pour rester cohérent avec les autres postes), puis de relancer cet installateur.' + #13#10 + #13#10 +
        'Continuer quand même avec l''installation automatique (risque d''échec) ?',
        mbConfirmation, MB_YESNO) = IDYES);
    end;
  end;
end;

// Les fichiers marqués "dontcopy" dans [Files] ne sont JAMAIS extraits
// automatiquement (contrairement à un [Files] normal) - sans cet appel
// explicite, {tmp}\Vigie-*.exe n'existe pas quand [Run] essaie de le
// lancer, et l'installation échoue ("fichier introuvable"). On extrait
// seulement ce qui a été coché, juste avant que [Run] ne s'exécute.
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    if WizardIsComponentSelected('billets') then
      ExtractTemporaryFile(GetBilletsInstallerFile(''));
    if WizardIsComponentSelected('parc') then
      ExtractTemporaryFile('Vigie-Parc-Installateur.exe');
    if WizardIsComponentSelected('inventory') then
      ExtractTemporaryFile('Vigie-Inventory-Installateur.exe');
    if WizardIsComponentSelected('simulation') then
      ExtractTemporaryFile('Vigie-Simulation-Installateur.exe');
    if WizardIsComponentSelected('suite') then
      ExtractTemporaryFile('Vigie-Suite-Installateur.exe');
  end;
end;
