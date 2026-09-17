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
# installé — jamais deviné ni codé en dur ici (un mauvais mot de passe
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

try {

$SetupDir = Join-Path $InstallDir "_setup"
$NssmExe  = Join-Path $SetupDir "nssm.exe"

Log "=== Installation Vigie Parc — démarrage ==="

# ── 1) Vérifier que Vigie Billets (Node.js + PostgreSQL + tickets_db) est déjà là ──
# Vigie Parc n'installe rien lui-même — il réutilise Node.js, PostgreSQL et la
# base de données déjà mis en place par Vigie Billets sur ce poste.
Update-PathFromMachine
$nodeOk = $false
try { $v = & node --version 2>$null; if ($v) { $nodeOk = $true; Log "Node.js présent ($v)" } } catch {}
if (-not $nodeOk) {
  throw "Node.js n'a pas été trouvé sur ce poste. Vigie Parc nécessite que Vigie Billets soit déjà installé (il réutilise son Node.js et sa base de données) — installez Vigie Billets d'abord."
}

$PgBin = "C:\Program Files\PostgreSQL\18\bin"
$psql  = Join-Path $PgBin "psql.exe"
if (-not (Test-Path $psql)) {
  throw "PostgreSQL n'a pas été trouvé sur ce poste. Vigie Parc nécessite que Vigie Billets soit déjà installé — installez Vigie Billets d'abord."
}

$PgPassword = Read-BilletsPgPassword
if (-not $PgPassword) {
  throw "Impossible de lire le mot de passe PostgreSQL depuis le service Vigie Billets déjà installé. Vigie Parc nécessite que Vigie Billets soit installé et fonctionnel sur ce poste."
}
$env:PGPASSWORD = $PgPassword
$dbExists = (& $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='tickets_db'") -join ''
if ($dbExists -ne '1') {
  throw "La base de données tickets_db est introuvable. Vigie Parc nécessite que Vigie Billets soit déjà installé — installez Vigie Billets d'abord."
}
Log "Base tickets_db trouvée (partagée avec Vigie Billets)."

# ── 2) Secrets applicatifs ────────────────────────────────────────────────
# JWT_SECRET propre à Vigie Parc (comptes/sessions indépendants de Billets,
# même si la base de données est partagée).
$JwtSecret = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 48 | ForEach-Object {[char]$_})

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

# ── 4) Pare-feu — accès depuis le réseau local ───────────────────────────
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
$LanIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
  $_.IPAddress -notmatch '^169\.254\.' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
} | Select-Object -First 1 -ExpandProperty IPAddress)

$infoPath = Join-Path $InstallDir "IMPORTANT - Identifiants.txt"
@"
Vigie Parc — Installation terminée
===================================
Adresse sur ce poste       : http://localhost:3501
Adresse depuis le réseau local : http://$LanIp`:3501
  (l'adresse réseau peut changer si le routeur la réattribue — réservez
   cette IP pour ce poste dans les paramètres du routeur pour l'éviter)

Connexion administrateur par défaut :
  Numéro d'employé : ADMIN001
  Mot de passe      : Admin1234!
  (changement obligatoire à la première connexion — ignorez si ce poste avait déjà des données)

Secret généré automatiquement (gardez ce fichier en lieu sûr, puis supprimez-le du bureau) :
  JWT_SECRET = $JwtSecret

Vigie Parc réutilise la base de données de Vigie Billets (tickets_db) mais
possède ses propres comptes employés/techniciens/admin, indépendants de
Vigie Billets.

Le serveur tourne en service Windows (VigieParc) — démarre automatiquement avec Windows.
"@ | Out-File -FilePath $infoPath -Encoding UTF8
Copy-Item -Path $infoPath -Destination "$env:PUBLIC\Desktop\IMPORTANT - Identifiants Vigie Parc.txt" -Force

Log "=== Installation terminée avec succès ==="

} catch {
  Log "❌ ERREUR FATALE: $($_.Exception.Message)"
  Log ($_.ScriptStackTrace -replace "`n", " | ")
  exit 1
}
