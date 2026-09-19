param(
  [Parameter(Mandatory=$true)][string]$InstallDir
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $InstallDir "install-log.txt"
function Log($msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}

function Update-PathFromMachine {
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
}

function Invoke-Nssm {
  param([string[]]$NssmArgs)
  try {
    & $script:NssmExe @NssmArgs 2>&1 | ForEach-Object { Log "  nssm> $_" }
  } catch {
    Log "  (nssm $($NssmArgs -join ' ') a signalé: $($_.Exception.Message))"
  }
}

# Lit PGPASSWORD depuis la configuration NSSM du service Vigie Billets déjà
# installé - jamais deviné ni codé en dur ici (un mauvais mot de passe
# ferait planter le reste en silence, et un mot de passe en clair dans le
# script serait visible dans le dépôt public vigie-installateur).
function Read-BilletsPgPassword {
  $billetsDir = $null
  try {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{8F3C1A2B-6D4E-4A7F-9B12-3E5C7D9A1F00}_is1'
    $billetsDir = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
  } catch {}
  if (-not $billetsDir) { return $null }
  $billetsNssm = Join-Path $billetsDir "_setup\nssm.exe"
  if (-not (Test-Path $billetsNssm)) { return $null }
  $envLines = & $billetsNssm get VigieBillets AppEnvironmentExtra 2>$null
  foreach ($line in $envLines) {
    if ($line -like 'PGPASSWORD=*') { return $line.Substring(11) }
  }
  return $null
}

# ── Mise à jour sans risque pour les données ─────────────────────────────────
# Lit la configuration du service Windows DÉJÀ installé (mot de passe PostgreSQL et secret de session)
# pour qu'une mise à jour reprenne exactement les mêmes valeurs : l'accès à la base est garanti
# (jamais deviné) et les utilisateurs restent connectés.
function Get-ExistingServiceEnv([string]$Name) {
  $r = @{ PGPASSWORD = $null; JWT_SECRET = $null }
  try {
    $lines = & $script:NssmExe get $Name AppEnvironmentExtra 2>$null
    foreach ($l in $lines) {
      $s = "$l".Trim()
      if ($s -like 'PGPASSWORD=*')  { $r.PGPASSWORD  = $s.Substring(11) }
      elseif ($s -like 'JWT_SECRET=*') { $r.JWT_SECRET = $s.Substring(11) }
    }
  } catch {}
  return $r
}

# Copie de sécurité de la base AVANT toute mise à jour (fichier .sql dans le dossier backups de
# l'application, visible dans Paramètres > Données, 3 dernières conservées). La mise à jour ne modifie
# jamais les données existantes : cette copie est une assurance supplémentaire. Un échec de copie
# n'interrompt pas la mise à jour.
function Backup-DatabaseBeforeUpdate([string]$Psql, [string]$PgDump, [string]$Database, [string]$Dir) {
  try {
    $has = (& $Psql -U postgres -h localhost -d $Database -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' LIMIT 1") -join ''
    if ($has -ne '1') { return }
    $bdir = Join-Path $Dir 'backups'
    New-Item -ItemType Directory -Force -Path $bdir | Out-Null
    $file = Join-Path $bdir ("avant-mise-a-jour_{0}_{1}.sql" -f $Database, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    & $PgDump -U postgres -h localhost -d $Database -F p -f $file 2>&1 | Out-Null
    if ((Test-Path $file) -and ((Get-Item $file).Length -gt 0)) {
      Log "Copie de sécurité de la base créée avant la mise à jour : $file"
      Get-ChildItem $bdir -Filter 'avant-mise-a-jour_*.sql' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
      Log "Copie de sécurité non créée (la mise à jour continue, les données ne sont pas modifiées)."
    }
  } catch { Log "Copie de sécurité impossible : $($_.Exception.Message) (la mise à jour continue, les données ne sont pas modifiées)" }
}

try {

$SetupDir = Join-Path $InstallDir "_setup"
$NssmExe  = Join-Path $SetupDir "nssm.exe"

Log "=== Installation Vigie Parc - démarrage ==="

# ── 1) Vérifier que Vigie Billets (Node.js + PostgreSQL + tickets_db) est déjà là ──
# Vigie Parc n'installe rien lui-même - il réutilise Node.js, PostgreSQL et la
# base de données déjà mis en place par Vigie Billets sur ce poste.
Update-PathFromMachine
$nodeOk = $false
try { $v = & node --version 2>$null; if ($v) { $nodeOk = $true; Log "Node.js présent ($v)" } } catch {}
if (-not $nodeOk) {
  throw "Node.js n'a pas été trouvé sur ce poste. Vigie Parc nécessite que Vigie Billets soit déjà installé (il réutilise son Node.js et sa base de données) - installez Vigie Billets d'abord."
}

$PgBin = "C:\Program Files\PostgreSQL\18\bin"
$psql  = Join-Path $PgBin "psql.exe"
if (-not (Test-Path $psql)) {
  throw "PostgreSQL n'a pas été trouvé sur ce poste. Vigie Parc nécessite que Vigie Billets soit déjà installé - installez Vigie Billets d'abord."
}

$PgPassword = Read-BilletsPgPassword
if (-not $PgPassword) {
  throw "Impossible de lire le mot de passe PostgreSQL depuis le service Vigie Billets déjà installé. Vigie Parc nécessite que Vigie Billets soit installé et fonctionnel sur ce poste."
}
$env:PGPASSWORD = $PgPassword
$dbExists = (& $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='tickets_db'") -join ''
if ($dbExists -ne '1') {
  throw "La base de données tickets_db est introuvable. Vigie Parc nécessite que Vigie Billets soit déjà installé - installez Vigie Billets d'abord."
}
Log "Base tickets_db trouvée (partagée avec Vigie Billets)."
$existing = Get-ExistingServiceEnv 'VigieParc'   # configuration du service déjà installé (mise à jour)
Backup-DatabaseBeforeUpdate $psql (Join-Path $PgBin 'pg_dump.exe') 'tickets_db' $InstallDir

# ── 2) Secrets applicatifs ────────────────────────────────────────────────
# JWT_SECRET propre à Vigie Parc (comptes/sessions indépendants de Billets,
# même si la base de données est partagée).
$JwtSecret = $existing.JWT_SECRET
if ($JwtSecret) { Log "Secret de session existant conservé (les utilisateurs restent connectés)." }
else { $JwtSecret = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_}) }

# ── 3) Service Windows (via NSSM) ────────────────────────────────────────
Update-PathFromMachine
$NodeExePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExePath) { $NodeExePath = "C:\Program Files\nodejs\node.exe" }

$ServiceName = "VigieParc"
Log "Configuration du service Windows '$ServiceName'..."
Invoke-Nssm @('stop', $ServiceName)
Invoke-Nssm @('remove', $ServiceName, 'confirm')
Invoke-Nssm @('install', $ServiceName, $NodeExePath)
Invoke-Nssm @('set', $ServiceName, 'AppDirectory', $InstallDir)
Invoke-Nssm @('set', $ServiceName, 'AppParameters', 'server.js')
Invoke-Nssm @('set', $ServiceName, 'AppEnvironmentExtra', "JWT_SECRET=$JwtSecret", "PGPASSWORD=$PgPassword", "NODE_ENV=production", "PORT=3501")
Invoke-Nssm @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
Invoke-Nssm @('set', $ServiceName, 'AppStdout', (Join-Path $InstallDir "service-out.log"))
Invoke-Nssm @('set', $ServiceName, 'AppStderr', (Join-Path $InstallDir "service-err.log"))
Invoke-Nssm @('start', $ServiceName)
Start-Sleep -Seconds 3

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
  Log "Service démarré avec succès."
} else {
  Log "⚠️ Le service ne semble pas démarré (statut: $($svc.Status)). Vérifiez service-err.log."
}

# ── 4) Pare-feu - accès depuis le réseau local ───────────────────────────
try {
  Get-NetFirewallRule -DisplayName "Vigie Parc (port 3501)" -ErrorAction Stop | Out-Null
  Log "Règle de pare-feu déjà présente."
} catch {
  try {
    New-NetFirewallRule -DisplayName "Vigie Parc (port 3501)" -Direction Inbound -Protocol TCP -LocalPort 3501 -Action Allow -Profile Any | Out-Null
    Log "Règle de pare-feu ajoutée (port 3501 ouvert pour le réseau local)."
  } catch {
    Log "⚠️ Impossible d'ajouter la règle de pare-feu automatiquement: $($_.Exception.Message)"
  }
}

# ── 5) Raccourci bureau ───────────────────────────────────────────────────
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\Vigie Parc.lnk")
$Shortcut.TargetPath = "http://localhost:3501"
$Shortcut.IconLocation = Join-Path $InstallDir "public\brand\vigie-parc.ico"
$Shortcut.Save()

# ── 6) Icône dans la barre système (démarre avec Windows, pour tous les comptes) ──
Log "Configuration de l'icône dans la barre système..."
$StartupFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$TrayShortcut = $WshShell.CreateShortcut((Join-Path $StartupFolder "Vigie Parc (icone).lnk"))
$TrayShortcut.TargetPath = "powershell.exe"
$TrayShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\tray.ps1`" -InstallDir `"$InstallDir`" -ServiceName `"$ServiceName`""
$TrayShortcut.WorkingDirectory = $InstallDir
$TrayShortcut.WindowStyle = 7
$TrayShortcut.Save()
try {
  $trayProc = Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\tray.ps1`" -InstallDir `"$InstallDir`" -ServiceName `"$ServiceName`"" -PassThru
  $trayProc.Id | Out-File -FilePath (Join-Path $InstallDir "tray.pid") -Encoding ASCII
  Log "Icône système démarrée (PID $($trayProc.Id))."
} catch {
  Log "⚠️ Icône système non démarrée: $($_.Exception.Message)"
}

# ── 7) Fichier de récapitulatif ──────────────────────────────────────────
# Préfère l'adaptateur Wi-Fi/Ethernet réel - sinon, sur un poste avec un VPN
# actif (NordVPN, Tailscale, etc.), ce filtre pouvait choisir l'adresse du
# tunnel VPN à la place, une adresse qu'aucun autre appareil du réseau
# local ne peut jamais joindre.
$LanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
  $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' -and
  $_.InterfaceAlias -match '^(Wi-?Fi|Ethernet)'
} | Select-Object -First 1 -ExpandProperty IPAddress)
if (-not $LanIp) {
  $LanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
  } | Select-Object -First 1 -ExpandProperty IPAddress)
}

$infoPath = Join-Path $InstallDir "IMPORTANT - Identifiants.txt"
@"
Vigie Parc - Installation terminée
===================================
Adresse sur ce poste       : http://localhost:3501
Adresse depuis le réseau local : http://$LanIp`:3501
  (l'adresse réseau peut changer si le routeur la réattribue - réservez
   cette IP pour ce poste dans les paramètres du routeur pour l'éviter)

Connexion administrateur par défaut :
  Numéro d'employé : ADMIN001
  Mot de passe      : Admin1234!
  (changement obligatoire à la première connexion - ignorez si ce poste avait déjà des données)

Secret généré automatiquement (gardez ce fichier en lieu sûr, puis supprimez-le du bureau) :
  JWT_SECRET = $JwtSecret

Vigie Parc réutilise la base de données de Vigie Billets (tickets_db) mais
possède ses propres comptes employés/techniciens/admin, indépendants de
Vigie Billets.

Le serveur tourne en service Windows (VigieParc) - démarre automatiquement avec Windows.
"@ | Out-File -FilePath $infoPath -Encoding UTF8
Copy-Item -Path $infoPath -Destination "$env:PUBLIC\Desktop\IMPORTANT - Identifiants Vigie Parc.txt" -Force

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  # La mise à jour a échoué : remettre en marche le service déjà installé (les données n'ont pas été modifiées).
  try { $prev = Get-Service -Name 'VigieParc' -ErrorAction SilentlyContinue; if ($prev -and $prev.Status -ne 'Running') { Start-Service -Name $prev.Name; Log "Ancien service redémarré : la mise à jour a échoué, les données sont intactes." } } catch {}
  exit 1
}
