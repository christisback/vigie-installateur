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

try {

$SetupDir = Join-Path $InstallDir "_setup"
$NodeMsi  = Join-Path $SetupDir "node-v24.19.0-x64.msi"
$NssmExe  = Join-Path $SetupDir "nssm.exe"

Log "=== Installation Vigie Inventory — démarrage ==="

# ── 1) Node.js ────────────────────────────────────────────────────────────
Update-PathFromMachine
$nodeOk = $false
try { $v = & node --version 2>$null; if ($v) { $nodeOk = $true; Log "Node.js déjà présent ($v)" } } catch {}
if (-not $nodeOk) {
  Log "Installation de Node.js LTS..."
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$NodeMsi`" /qn /norestart" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "Échec installation Node.js (code $($p.ExitCode))" }
  Update-PathFromMachine
  Log "Node.js installé."
}

# ── 2) PostgreSQL ─────────────────────────────────────────────────────────
# Vigie Inventory ne réinstalle jamais PostgreSQL lui-même — s'il n'est pas
# déjà présent (via Vigie Billets ou une installation manuelle), on demande
# de l'installer d'abord plutôt que de deviner un mot de passe ou d'en
# écrire un dans ce script (visible dans le dépôt public vigie-installateur).
$PgBin = "C:\Program Files\PostgreSQL\18\bin"
$psql  = Join-Path $PgBin "psql.exe"
if (-not (Test-Path $psql)) {
  throw "PostgreSQL n'a pas été trouvé sur ce poste (C:\Program Files\PostgreSQL\18). Installez d'abord Vigie Billets (qui installe PostgreSQL), puis relancez cet installateur."
}

$PgPassword = $env:PGPASSWORD_EXISTANT
if (-not $PgPassword) {
  # Tente de lire le mot de passe déjà connu depuis un autre service Vigie
  # installé sur ce poste (même instance PostgreSQL partagée) plutôt que de
  # le deviner ou d'en coder un en dur ici.
  foreach ($svc in @(
    @{ Name = 'VigieBillets';   Key = '{8F3C1A2B-6D4E-4A7F-9B12-3E5C7D9A1F00}' },
    @{ Name = 'VigieParc';      Key = '{A36745F6-2B1B-48B0-9A86-54BA0911A6DA}' }
  )) {
    try {
      $dir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($svc.Key)_is1" -ErrorAction Stop).InstallLocation
      $svcNssm = Join-Path $dir "_setup\nssm.exe"
      if (Test-Path $svcNssm) {
        $envLines = & $svcNssm get $svc.Name AppEnvironmentExtra 2>$null
        foreach ($line in $envLines) {
          if ($line -like 'PGPASSWORD=*') { $PgPassword = $line.Substring(11); break }
        }
      }
    } catch {}
    if ($PgPassword) { break }
  }
}
if (-not $PgPassword) {
  throw "PostgreSQL est déjà installé sur ce poste mais le mot de passe superutilisateur n'a pas pu être déterminé automatiquement. Relancez l'installateur avec la variable d'environnement PGPASSWORD_EXISTANT définie sur le vrai mot de passe PostgreSQL de ce poste."
}
$env:PGPASSWORD = $PgPassword
$testConn = & $psql -U postgres -h localhost -tAc "SELECT 1" 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "La connexion à PostgreSQL avec le mot de passe trouvé a échoué. Relancez l'installateur avec la variable d'environnement PGPASSWORD_EXISTANT définie sur le vrai mot de passe PostgreSQL de ce poste."
}
Log "Connexion à PostgreSQL existant vérifiée."

# ── 3) Base de données ────────────────────────────────────────────────────
# Le schéma (tables) se crée lui-même au premier démarrage du serveur
# (migrations idempotentes CREATE TABLE IF NOT EXISTS dans server.js) — on
# n'a besoin de créer que la base elle-même ici.
$dbExists = (& $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='vigie_inventory_db'") -join ''
if ($dbExists -ne '1') {
  & $psql -U postgres -h localhost -c "CREATE DATABASE vigie_inventory_db" | Out-Null
  Log "Base vigie_inventory_db créée."
} else {
  Log "Base vigie_inventory_db déjà présente."
}

# ── 4) Secrets applicatifs ────────────────────────────────────────────────
$JwtSecret = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_})

# ── 5) Service Windows (via NSSM) ────────────────────────────────────────
Update-PathFromMachine
$NodeExePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExePath) { $NodeExePath = "C:\Program Files\nodejs\node.exe" }

$ServiceName = "VigieInventory"
Log "Configuration du service Windows '$ServiceName'..."
Invoke-Nssm @('stop', $ServiceName)
Invoke-Nssm @('remove', $ServiceName, 'confirm')
Invoke-Nssm @('install', $ServiceName, $NodeExePath)
Invoke-Nssm @('set', $ServiceName, 'AppDirectory', $InstallDir)
Invoke-Nssm @('set', $ServiceName, 'AppParameters', 'server.js')
Invoke-Nssm @('set', $ServiceName, 'AppEnvironmentExtra', "JWT_SECRET=$JwtSecret", "PGPASSWORD=$PgPassword", "PGDATABASE=vigie_inventory_db", "NODE_ENV=production", "PORT=3502")
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

# ── 5b) Pare-feu — accès depuis le réseau local ──────────────────────────
try {
  Get-NetFirewallRule -DisplayName "Vigie Inventory (port 3502)" -ErrorAction Stop | Out-Null
  Log "Règle de pare-feu déjà présente."
} catch {
  try {
    New-NetFirewallRule -DisplayName "Vigie Inventory (port 3502)" -Direction Inbound -Protocol TCP -LocalPort 3502 -Action Allow -Profile Any | Out-Null
    Log "Règle de pare-feu ajoutée (port 3502 ouvert pour le réseau local)."
  } catch {
    Log "⚠️ Impossible d'ajouter la règle de pare-feu automatiquement: $($_.Exception.Message)"
  }
}

# ── 6) Raccourci bureau ───────────────────────────────────────────────────
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\Vigie Inventory.lnk")
$Shortcut.TargetPath = "http://localhost:3502"
$Shortcut.IconLocation = Join-Path $InstallDir "public\brand\vigie-inventory.ico"
$Shortcut.Save()

# ── 7) Icône dans la barre système (démarre avec Windows, pour tous les comptes) ──
Log "Configuration de l'icône dans la barre système..."
$StartupFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$TrayShortcut = $WshShell.CreateShortcut((Join-Path $StartupFolder "Vigie Inventory (icone).lnk"))
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

# ── 8) Fichier de récapitulatif ──────────────────────────────────────────
# Préfère l'adaptateur Wi-Fi/Ethernet réel — sinon, sur un poste avec un VPN
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
Vigie Inventory — Installation terminée
========================================
Adresse sur ce poste       : http://localhost:3502
Adresse depuis le réseau local : http://$LanIp`:3502
  (l'adresse réseau peut changer si le routeur la réattribue — réservez
   cette IP pour ce poste dans les paramètres du routeur pour l'éviter)

Connexion administrateur par défaut :
  Numéro d'employé : ADMIN001
  Mot de passe      : Admin1234!
  (changement obligatoire à la première connexion — ignorez si ce poste avait déjà des données)

Secrets générés automatiquement (gardez ce fichier en lieu sûr, puis supprimez-le du bureau) :
  JWT_SECRET = $JwtSecret
  PGPASSWORD = $PgPassword

Vigie Inventory est un produit autonome : sa propre base de données
(vigie_inventory_db), ses propres comptes — aucune dépendance à Vigie
Billets ou Vigie Parc. Les catégories de matériel, départements et champs
personnalisés se configurent dans Paramètres pour adapter l'outil à
n'importe quelle entreprise.

Le serveur tourne en service Windows (VigieInventory) — démarre automatiquement avec Windows.
"@ | Out-File -FilePath $infoPath -Encoding UTF8
Copy-Item -Path $infoPath -Destination "$env:PUBLIC\Desktop\IMPORTANT - Identifiants Vigie Inventory.txt" -Force

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  exit 1
}
