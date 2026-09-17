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

# Exécute nssm.exe en tolérant les erreurs (nssm écrit sur stderr même pour des
# opérations bénignes comme "stop" un service qui n'existe pas encore — sous
# PowerShell 5.1 ceci peut se transformer en erreur bloquante si on la laisse
# remonter, d'où le try/catch systématique ici).
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
$PgExe    = Join-Path $SetupDir "postgresql-18.6-1-windows-x64.exe"
$NssmExe  = Join-Path $SetupDir "nssm.exe"

Log "=== Installation Vigie Billets — démarrage ==="

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
$PgBin = "C:\Program Files\PostgreSQL\18\bin"
$psql  = Join-Path $PgBin "psql.exe"
$pgOk  = Test-Path $psql

if (-not $pgOk) {
  $PgPassword = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_})
  Log "Installation de PostgreSQL 18 (peut prendre quelques minutes)..."
  # Les valeurs contenant des espaces (chemins sous "Program Files") doivent être
  # explicitement entre guillemets ICI — Start-Process -ArgumentList ne met PAS
  # automatiquement des guillemets autour des éléments d'un tableau qui en
  # contiennent, il les joint tel quel par un espace. Sans ces guillemets,
  # "C:\Program Files\PostgreSQL\18" devient DEUX arguments distincts pour
  # l'installateur PostgreSQL ("C:\Program" et "Files\PostgreSQL\18"), qui
  # échoue alors avec "option attendu mais contient Files\PostgreSQL\18".
  $pgArgs = @(
    '--mode', 'unattended', '--unattendedmodeui', 'minimal',
    '--installdir', '"C:\Program Files\PostgreSQL\18"',
    '--datadir', '"C:\Program Files\PostgreSQL\18\data"',
    '--serverport', '5432',
    '--superpassword', $PgPassword,
    '--servicename', 'postgresql-x64-18',
    '--disable-components', 'pgAdmin,stackbuilder'
  )
  $p = Start-Process -FilePath $PgExe -ArgumentList $pgArgs -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "Échec installation PostgreSQL (code $($p.ExitCode))" }
  Log "PostgreSQL installé."
  Start-Sleep -Seconds 5
} else {
  # PostgreSQL est déjà là (ex: réinstallation sur un poste déjà configuré).
  # On ne connaît PAS son mot de passe superutilisateur — on ne le devine
  # jamais au hasard, car un mauvais mot de passe ferait planter tout le
  # reste en silence (c'est exactement ce qui est arrivé la première fois).
  Log "PostgreSQL déjà présent sur ce poste."
  $PgPassword = $env:PGPASSWORD_EXISTANT
  if (-not $PgPassword) { $PgPassword = "123" }  # mot de passe par défaut historique de l'app, en dernier recours
  $env:PGPASSWORD = $PgPassword
  $testConn = & $psql -U postgres -h localhost -tAc "SELECT 1" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "PostgreSQL est déjà installé sur ce poste mais le mot de passe n'a pas pu être vérifié (essayé: mot de passe par défaut). Relancez l'installateur avec la variable d'environnement PGPASSWORD_EXISTANT définie sur le vrai mot de passe PostgreSQL de ce poste."
  }
  Log "Connexion à PostgreSQL existant vérifiée."
}

# ── 3) Base de données + schéma ──────────────────────────────────────────
$env:PGPASSWORD = $PgPassword
$dbExists = (& $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='tickets_db'") -join ''
if ($dbExists -ne '1') {
  & $psql -U postgres -h localhost -c "CREATE DATABASE tickets_db" | Out-Null
  Log "Base tickets_db créée."
}

# Protection anti-écrasement : si la table employees existe déjà, la base
# contient probablement de vraies données — on n'applique JAMAIS schema.sql
# dessus (il commence par des DROP TABLE).
$schemaAlreadyThere = (& $psql -U postgres -h localhost -d tickets_db -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='employees'") -join ''
if ($schemaAlreadyThere -eq '1') {
  Log "Des tables existent déjà dans tickets_db — schema.sql NON appliqué (protection des données existantes)."
} else {
  & $psql -U postgres -h localhost -d tickets_db -f (Join-Path $InstallDir "schema.sql") | Out-Null
  Log "Schéma appliqué."
}

# ── 4) Secrets applicatifs ────────────────────────────────────────────────
$JwtSecret = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_})
[System.Environment]::SetEnvironmentVariable('JWT_SECRET', $JwtSecret, 'Machine')
[System.Environment]::SetEnvironmentVariable('PGPASSWORD', $PgPassword, 'Machine')
Log "Variables d'environnement système configurées."

# ── 5) Service Windows (via NSSM) ────────────────────────────────────────
Update-PathFromMachine
$NodeExePath = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExePath) { $NodeExePath = "C:\Program Files\nodejs\node.exe" }

$ServiceName = "VigieBillets"
Log "Configuration du service Windows '$ServiceName'..."
Invoke-Nssm @('stop', $ServiceName)
Invoke-Nssm @('remove', $ServiceName, 'confirm')
Invoke-Nssm @('install', $ServiceName, $NodeExePath)
Invoke-Nssm @('set', $ServiceName, 'AppDirectory', $InstallDir)
# AppParameters en chemin RELATIF ("server.js", pas le chemin complet) : le
# dossier de travail (AppDirectory) est déjà réglé sur $InstallDir, donc
# node.exe trouve le fichier sans qu'on ait à gérer les guillemets autour
# d'un chemin contenant des espaces ("C:\Program Files\...") — la tentative
# précédente avec le chemin complet entre guillemets échouait encore
# (MODULE_NOT_FOUND) à cause d'un problème de citation PowerShell → nssm.exe.
Invoke-Nssm @('set', $ServiceName, 'AppParameters', 'server.js')
Invoke-Nssm @('set', $ServiceName, 'AppEnvironmentExtra', "JWT_SECRET=$JwtSecret", "PGPASSWORD=$PgPassword", "NODE_ENV=production", "PORT=3500")
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
  Get-NetFirewallRule -DisplayName "Vigie Billets (port 3500)" -ErrorAction Stop | Out-Null
  Log "Règle de pare-feu déjà présente."
} catch {
  try {
    New-NetFirewallRule -DisplayName "Vigie Billets (port 3500)" -Direction Inbound -Protocol TCP -LocalPort 3500 -Action Allow -Profile Any | Out-Null
    Log "Règle de pare-feu ajoutée (port 3500 ouvert pour le réseau local)."
  } catch {
    Log "⚠️ Impossible d'ajouter la règle de pare-feu automatiquement: $($_.Exception.Message)"
  }
}

# ── 6) Raccourci bureau ───────────────────────────────────────────────────
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\Vigie Billets.lnk")
$Shortcut.TargetPath = "http://localhost:3500"
$Shortcut.IconLocation = Join-Path $InstallDir "brand\vigie-billets.ico"
$Shortcut.Save()

# ── 7) Icône dans la barre système (démarre avec Windows, pour tous les comptes) ──
Log "Configuration de l'icône dans la barre système..."
$StartupFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$TrayShortcut = $WshShell.CreateShortcut((Join-Path $StartupFolder "Vigie Billets (icône).lnk"))
$TrayShortcut.TargetPath = "powershell.exe"
$TrayShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\tray.ps1`" -InstallDir `"$InstallDir`" -ServiceName `"$ServiceName`""
$TrayShortcut.WorkingDirectory = $InstallDir
$TrayShortcut.WindowStyle = 7
$TrayShortcut.Save()
# Lancer tout de suite (sans attendre la prochaine ouverture de session)
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
# tunnel VPN à la place (ex: 10.5.0.2 via NordLynx), une adresse qu'aucun
# autre appareil du réseau local ne peut jamais joindre.
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
Vigie Billets — Installation terminée
=====================================
Adresse sur ce poste       : http://localhost:3500
Adresse depuis le réseau local : http://$LanIp`:3500
  (l'adresse réseau peut changer si le routeur la réattribue — réservez
   cette IP pour ce poste dans les paramètres du routeur pour l'éviter)

Connexion administrateur par défaut :
  Numéro d'employé : ADMIN001
  Mot de passe      : Admin1234!
  (changement obligatoire à la première connexion — ignorez si ce poste avait déjà des données)

Secrets générés automatiquement (gardez ce fichier en lieu sûr, puis supprimez-le du bureau) :
  JWT_SECRET = $JwtSecret
  PGPASSWORD = $PgPassword

Le serveur tourne en service Windows ($ServiceName) — démarre automatiquement avec Windows.
"@ | Out-File -FilePath $infoPath -Encoding UTF8
Copy-Item -Path $infoPath -Destination "$env:PUBLIC\Desktop\IMPORTANT - Identifiants Vigie Billets.txt" -Force

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  exit 1
}



